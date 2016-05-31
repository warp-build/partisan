%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Christopher Meiklejohn.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(partisan_hyparview_peer_service_manager).
-author("Christopher S. Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(gen_server).
-behaviour(partisan_peer_service_manager).

-define(PASSIVE_VIEW_MAINTENANCE_INTERVAL, 10000).
-define(ACTIVE_SIZE, 5).
-define(PASSIVE_SIZE, 30).
-define(ARWL, 6).
-define(PRWL, 3).

-include("partisan.hrl").

%% partisan_peer_service_manager callbacks
-export([start_link/0,
         members/0,
         get_local_state/0,
         join/1,
         leave/0,
         leave/1,
         send_message/2,
         forward_message/3,
         receive_message/1,
         decode/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% temporary exceptions
-export([delete_state_from_disk/0]).

-type active() :: sets:set(node_spec()).
-type passive() :: sets:set(node_spec()).
-type pending() :: sets:set(node_spec()).
-type suspected() :: sets:set(node_spec()).

-record(state, {actor :: actor(),
                active :: active(),
                passive :: passive(),
                pending :: pending(),
                suspected :: suspected(),
                connections :: connections()}).

%%%===================================================================
%%% partisan_peer_service_manager callbacks
%%%===================================================================

%% @doc Same as start_link([]).
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Return membership list.
members() ->
    gen_server:call(?MODULE, members, infinity).

%% @doc Return local node's view of cluster membership.
get_local_state() ->
    gen_server:call(?MODULE, get_local_state, infinity).

%% @doc Send message to a remote manager.
send_message(Name, Message) ->
    lager:info("Sending message to ~p, ~p", [Name, Message]),
    gen_server:call(?MODULE, {send_message, Name, Message}, infinity).

%% @doc Forward message to registered process on the remote side.
forward_message(Name, ServerRef, Message) ->
    gen_server:call(?MODULE, {forward_message, Name, ServerRef, Message}, infinity).

%% @doc Receive message from a remote manager.
receive_message(Message) ->
    lager:info("Receiving message ~p", [Message]),
    gen_server:call(?MODULE, {receive_message, Message}, infinity).

%% @doc Attempt to join a remote node.
join(Node) ->
    gen_server:call(?MODULE, {join, Node}, infinity).

%% @doc Leave the cluster.
leave() ->
    gen_server:call(?MODULE, {leave, node()}, infinity).

%% @doc Remove another node from the cluster.
leave(Node) ->
    gen_server:call(?MODULE, {leave, Node}, infinity).

%% @doc Decode state.
decode(Active) ->
    sets:to_list(Active).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
-spec init([]) -> {ok, #state{}}.
init([]) ->
    %% Seed the process at initialization.
    random:seed(erlang:phash2([node()]),
                erlang:monotonic_time(),
                erlang:unique_integer()),

    %% Process connection exits.
    process_flag(trap_exit, true),

    Actor = gen_actor(),
    {Active, Passive} = maybe_load_state_from_disk(Actor),
    Pending = sets:new(),
    Suspected = sets:new(),
    Connections = dict:new(),

    %% Schedule periodic maintenance of the passive view.
    schedule_passive_view_maintenance(),

    {ok, #state{pending=Pending,
                active=Active,
                passive=Passive,
                suspected=Suspected,
                connections=Connections}}.

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}}.

handle_call({leave, _Node}, _From, State) ->
    {reply, error, State};

handle_call({join, {_Name, _, _}=Node}, _From, State) ->
    gen_server:cast(?MODULE, {join, Node}),
    {reply, ok, State};

handle_call({send_message, Name, Message}, _From,
            #state{connections=Connections}=State) ->
    Result = do_send_message(Name, Message, Connections),
    {reply, Result, State};

handle_call({forward_message, Name, ServerRef, Message}, _From,
            #state{connections=Connections}=State) ->
    Result = do_send_message(Name,
                             {forward_message, ServerRef, Message},
                             Connections),
    {reply, Result, State};

handle_call({receive_message, Message}, _From, State) ->
    handle_message(Message, State);

handle_call(members, _From, #state{active=Active}=State) ->
    ActiveMembers = [P || {P, _, _} <- members(Active)],
    {reply, {ok, ActiveMembers}, State};

handle_call(get_local_state, _From, #state{active=Active}=State) ->
    {reply, {ok, Active}, State};

handle_call(Msg, _From, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {reply, ok, State}.

%% @private
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.

handle_cast({join, Peer},
            #state{pending=Pending0,
                   connections=Connections0}=State) ->
    %% Add to list of pending connections.
    Pending = add_to_pending(Peer, Pending0),

    %% Trigger connection.
    Connections = maybe_connect(Peer, Connections0, Pending),

    %% Return.
    {noreply, State#state{pending=Pending, connections=Connections}};

%% @doc Handle disconnect messages.
handle_cast({disconnect, Peer}, #state{active=Active0,
                                       connections=Connections0}=State0) ->
    case sets:is_element(Peer, Active0) of
        true ->
            %% If a member of the active view, remove it.
            Active = sets:del_element(Peer, Active0),
            State = add_to_passive_view(Peer,
                                        State0#state{active=Active}),
            Connections = disconnect(Peer, Connections0),
            {noreply, State#state{connections=Connections}};
        false ->
            {noreply, State0}
    end;

handle_cast({suspected, Peer}, #state{passive=Passive0,
                                      pending=Pending0,
                                      connections=Connections0}=State) ->
    lager:info("Node ~p suspected of failure.", [Peer]),

    %% Select random peer from passive view, and attempt to connect it.
    %%
    %% If it successfully connects, it will replace the failed node in
    %% the active view.
    %%
    Random = select_random(Passive0),

    %% Add to list of pending connections.
    Pending = add_to_pending(Random, Pending0),

    %% Trigger connection.
    Connections = maybe_connect(Random, Connections0, Pending),

    {noreply, State#state{pending=Pending, connections=Connections}};

handle_cast(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.

handle_info(passive_view_maintenance,
            #state{active=Active,
                   passive=Passive,
                   connections=Connections}=State) ->

    Exchange = %% Myself.
               [myself()] ++

               % Random members of the active list.
               select_random_sublist(Active, k_active()) ++

               %% Random members of the passive list.
               select_random_sublist(Passive, k_passive()),

    %% Select random member of the active list.
    Random = select_random(Active),

    %% Forward shuffle request.
    do_send_message(Random,
                    {shuffle, Exchange, arwl(), myself()},
                    Connections),

    {noreply, State};

handle_info({'EXIT', From, _Reason},
            #state{active=Active0,
                   passive=Passive0,
                   pending=Pending0,
                   suspected=Suspected0,
                   connections=Connections0}=State) ->
    %% Prune active connections from dictionary.
    FoldFun = fun(K, V, {Peer, AccIn}) ->
                      case V =:= From of
                          true ->
                              %% This *should* only ever match one.
                              AccOut = dict:store(K, undefined, AccIn),
                              {K, AccOut};
                          false ->
                              {Peer, AccIn}
                      end
              end,
    {Peer, Connections} = dict:fold(FoldFun,
                                    {undefined, Connections0},
                                    Connections0),

    %% If the connection was pending, and it exists in the passive view,
    %% that means we were attemping to use it as a replacement in the
    %% active view.
    %%
    %% We do the following:
    %%
    %% If pending, remove from pending.
    %%
    Pending = case is_pending(Peer, Pending0) of
        true ->
            remove_from_pending(Peer, Pending0);
        false ->
            Pending0
    end,

    %% If it was in the passive view and our connection attempt failed,
    %% remove from the passive view altogether.
    %%
    Passive = case is_in_passive_view(Peer, Passive0) of
        true ->
            remove_from_passive_view(Peer, Passive0);
        false ->
            Passive0
    end,

    %% If this node was a member of the active view, add it to a list of
    %% suspected active nodes that have failed and asynchronously fire
    %% off a message to schedule a connection to a random member of the
    %% passive set.
    %%
    Suspected = case is_in_active_view(Peer, Active0) of
        true ->
            add_to_suspected(Peer, Suspected0);
        false ->
            Suspected0
    end,

    %% If there are nodes still suspected of failure, schedule
    %% asynchronous message to find a replacement for these nodes.
    %%
    case is_empty(Suspected) of
        true ->
            ok;
        false ->
            gen_server:cast(?MODULE, {suspected, Peer})
    end,

    {noreply, State#state{pending=Pending,
                          passive=Passive,
                          suspected=Suspected,
                          connections=Connections}};

handle_info({connected, Peer, _RemoteState},
            #state{pending=Pending0,
                   passive=Passive0,
                   suspected=Suspected0}=State0) ->
    lager:info("Peer ~p connected.", [Peer]),

    %% When a node actually connects, perform the join steps.
    case is_pending(Peer, Pending0) of
        true ->
            %% Move out of pending.
            Pending = remove_from_pending(Peer, Pending0),

            %% If node is in the passive view, and we have a suspected
            %% node, that means it was
            %% contacted to be a potential node for replacement in the
            %% active view.
            %%
            case is_replacement_candidate(Peer, Passive0, Suspected0) of
                true ->
                    %% Send neighbor request to peer asking it to
                    %% replace a suspected node.
                    %%
                    State = send_neighbor(Peer,
                                          State0#state{pending=Pending}),

                    %% Notify with event.
                    notify(State),

                    {noreply, State};
                false ->
                    %% Normal join.
                    %%
                    State = perform_join(Peer,
                                         State0#state{pending=Pending}),

                    %% Notify with event.
                    notify(State),

                    {noreply, State}
            end;
        false ->
            {noreply, State0}
    end;

handle_info(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec terminate(term(), #state{}) -> term().
terminate(_Reason, #state{connections=Connections}=_State) ->
    dict:map(fun(_K, Pid) ->
                     try
                         gen_server:stop(Pid, normal, infinity)
                     catch
                         _:_ ->
                             ok
                     end
             end, Connections),
    ok.

%% @private
-spec code_change(term() | {down, term()}, #state{}, term()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
handle_message({neighbor_accepted, Peer, _Sender}, State0) ->
    State = add_to_active_view(Peer, State0),
    {reply, ok, State};

handle_message({neighbor_rejected, Peer, _Sender}, State) ->
    %% Trigger disconnect message.
    gen_server:cast(?MODULE, {disconnect, Peer}),

    {reply, ok, State};

handle_message({neighbor, Peer, Priority, Sender},
               #state{connections=Connections}=State0) ->
    State = case neighbor_acceptable(Priority, State0) of
        true ->
            %% Reply to acknowledge the neighbor was accepted.
            do_send_message(Sender,
                            {neighbor_accepted, Peer, myself()},
                            Connections),

            add_to_active_view(Peer, State0);
        false ->
            %% Reply to acknowledge the neighbor was rejected.
            do_send_message(Sender,
                            {neighbor_rejected, Peer, myself()},
                            Connections),

            State0
    end,
    {reply, ok, State};

handle_message({shuffle_reply, Exchange, _Sender}, State0) ->
    State = merge_exchange(Exchange, State0),
    {noreply, State};

handle_message({shuffle, Exchange, TTL, Sender},
               #state{active=Active0,
                      passive=Passive0,
                      connections=Connections}=State0) ->
    %% Forward to random member of the active view.
    State = case TTL > 0 andalso sets:size(Active0) > 1 of
        true ->
            Random = select_random(Active0, Sender),

            %% Forward shuffle until random walk complete.
            do_send_message(Random,
                            {shuffle, Exchange, TTL - 1, myself()},
                            Connections),

            State0;
        false ->
            %% Randomly select nodes from the passive view and respond.
            ResponseExchange = select_random_sublist(Passive0,
                                                     length(Exchange)),

            do_send_message(Sender,
                            {shuffle_reply, ResponseExchange, myself()},
                            Connections),

            merge_exchange(Exchange, State0)
    end,
    {noreply, State};

handle_message({forward_join, Peer, TTL, Sender},
               #state{active=Active0,
                      pending=Pending,
                      connections=Connections0}=State0) ->
    State = case TTL =:= 0 orelse sets:size(Active0) =:= 1 of
        true ->
            add_to_active_view(Peer, State0);
        false ->
            State1 = case TTL =:= prwl() of
                true ->
                    add_to_passive_view(Peer, State0);
                false ->
                    State0
            end,
            Random = select_random(Active0, Sender),

            %% Establish any new connections.
            Connections = establish_connections(Pending,
                                                Active0,
                                                Connections0),

            %% Forward join.
            do_send_message(Random,
                            {forward_join, Peer, TTL - 1, myself()},
                            Connections),

            State1
    end,
    {reply, ok, State};
handle_message({forward_message, ServerRef, Message}, State) ->
    gen_server:cast(ServerRef, Message),
    {reply, ok, State}.

%% @private
empty_membership(_Actor) ->
    %% Each cluster starts with only itself.
    Active = sets:add_element(myself(), sets:new()),
    Passive = sets:new(),
    LocalState = {Active, Passive},
    persist_state(LocalState),
    LocalState.

%% @private
gen_actor() ->
    Node = atom_to_list(node()),
    Unique = time_compat:unique_integer([positive]),
    TS = integer_to_list(Unique),
    Term = Node ++ TS,
    crypto:hash(sha, Term).

%% @private
data_root() ->
    case application:get_env(partisan, partisan_data_dir) of
        {ok, PRoot} ->
            filename:join(PRoot, "peer_service");
        undefined ->
            undefined
    end.

%% @private
write_state_to_disk(State) ->
    case data_root() of
        undefined ->
            ok;
        Dir ->
            File = filename:join(Dir, "cluster_state"),
            ok = filelib:ensure_dir(File),
            ok = file:write_file(File, term_to_binary(State))
    end.

%% @private
delete_state_from_disk() ->
    case data_root() of
        undefined ->
            ok;
        Dir ->
            File = filename:join(Dir, "cluster_state"),
            ok = filelib:ensure_dir(File),
            case file:delete(File) of
                ok ->
                    lager:info("Leaving cluster, removed cluster_state");
                {error, Reason} ->
                    lager:info("Unable to remove cluster_state for reason ~p", [Reason])
            end
    end.

%% @private
maybe_load_state_from_disk(Actor) ->
    case data_root() of
        undefined ->
            empty_membership(Actor);
        Dir ->
            case filelib:is_regular(filename:join(Dir, "cluster_state")) of
                true ->
                    {ok, Bin} = file:read_file(filename:join(Dir, "cluster_state")),
                    {ok, State} = binary_to_term(Bin),
                    State;
                false ->
                    empty_membership(Actor)
            end
    end.

%% @private
persist_state({Active, Passive}) ->
    write_state_to_disk({Active, Passive});
persist_state(#state{active=Active, passive=Passive}) ->
    persist_state({Active, Passive}).

%% @private
members(Set) ->
    sets:to_list(Set).

%% @private
establish_connections(Pending0, Set0, Connections) ->
    %% Reconnect disconnected members and members waiting to join.
    Set = members(Set0),
    Pending = members(Pending0),
    AllPeers = lists:keydelete(node(), 1, Set ++ Pending),
    lists:foldl(fun maybe_connect/3, Connections, AllPeers).

%% @private
%% Function should enforce the invariant that all cluster members are
%% keys in the dict pointing to undefined if they are disconnected or a
%% socket pid if they are connected.
%%
maybe_connect({Name, _, _} = Node, Connections0, Pending) ->
    Connections = case dict:find(Name, Connections0) of
        %% Found in dict, and disconnected.
        {ok, undefined} ->
            case connect(Node) of
                {ok, Pid} ->
                    dict:store(Name, Pid, Connections0);
                _ ->
                    dict:store(Name, undefined, Connections0)
            end;
        %% Found in dict and connected.
        {ok, Pid} ->
            case is_pending(Node, Pending) of
                true ->
                    lager:info("Node is still pending, not connected: ~p", [Node]),
                    exit(Pid, stalled),
                    case connect(Node) of
                        {ok, Pid} ->
                            dict:store(Name, Pid, Connections0);
                        _ ->
                            dict:store(Name, undefined, Connections0)
                    end;
                false ->
                    lager:info("Node ~p has registered pid.", [Node]),
                    Connections0
            end;
        %% Not present; disconnected.
        error ->
            lager:info("Node is not connected: ~p", [Node]),
            case connect(Node) of
                {ok, Pid} ->
                    dict:store(Name, Pid, Connections0);
                _ ->
                    dict:store(Name, undefined, Connections0)
            end
    end,
    Connections.

%% @private
connect(Node) ->
    Self = self(),
    partisan_peer_service_client:start_link(Node, Self).

%% @private
disconnect(Name, Connections) ->
    %% Find a connection for the remote node, if we have one.
    case dict:find(Name, Connections) of
        {ok, undefined} ->
            %% Return original set.
            Connections;
        {ok, Pid} ->
            %% Stop;
            gen_server:stop(Pid),

            %% Null out in the dictionary.
            dict:store(Name, undefined, Connections);
        error ->
            %% Return original set.
            Connections
    end.

%% @private
do_send_message(Name, Message, Connections) ->
    %% Find a connection for the remote node, if we have one.
    case dict:find(Name, Connections) of
        {ok, undefined} ->
            %% Node was connected but is now disconnected.
            {error, disconnected};
        {ok, Pid} ->
            gen_server:cast(Pid, {send_message, Message});
        error ->
            %% Node has not been connected yet.
            {error, not_yet_connected}
    end.

%% @private
select_random(View) ->
    select_random(View, undefined).

%% @private
select_random(View, Omit) ->
    List = members(View) -- [Omit],
    Index = random:uniform(length(List)),
    lists:nth(Index, List).

%% @private
select_random_sublist(View, K) ->
    List = members(View),
    lists:sublist(shuffle(List), K).

%% @doc Add to the active view.
add_to_active_view({Name, _, _}=Peer, #state{active=Active0}=State0) ->
    lager:info("Adding ~p to active view on ~p", [Peer, myself()]),
    IsNotMyself = not (Name =:= node()),
    NotInActiveView = not sets:is_element(Peer, Active0),
    case IsNotMyself andalso NotInActiveView of
        true ->
            #state{active=Active1} = State1 = case is_full({active, Active0}) of
                true ->
                    drop_random_element_from_active_view(State0);
                false ->
                    State0
            end,
            Active = sets:add_element(Peer, Active1),
            State2 = State1#state{active=Active},
            persist_state(State2),
            State2;
        false ->
            State0
    end.

%% @doc Add to the passive view.
add_to_passive_view({Name, _, _}=Peer,
                    #state{active=Active0, passive=Passive0}=State0) ->
    lager:info("Adding ~p to passive view on ~p", [Peer, myself()]),
    IsNotMyself = not (Name =:= node()),
    NotInActiveView = not sets:is_element(Peer, Active0),
    NotInPassiveView = not sets:is_element(Peer, Passive0),
    Passive = case IsNotMyself andalso NotInActiveView andalso NotInPassiveView of
        true ->
            Passive1 = case is_full({passive, Passive0}) of
                true ->
                    Random = select_random(Passive0),
                    sets:del_element(Random, Passive0);
                false ->
                    Passive0
            end,
            sets:add_element(Peer, Passive1);
        false ->
            Passive0
    end,
    State = State0#state{passive=Passive},
    persist_state(State),
    State.

%% @private
is_full({active, Active}) ->
    sets:size(Active) >= ?ACTIVE_SIZE;
is_full({passive, Passive}) ->
    sets:size(Passive) >= ?PASSIVE_SIZE.

%% @doc Process of removing a random element from the active view.
drop_random_element_from_active_view(#state{active=Active0,
                                            passive=Passive0}=State) ->
    %% Select random from the active view.
    Peer = select_random(Active0),

    %% Trigger disconnect message.
    gen_server:cast(?MODULE, {disconnect, Peer}),

    %% Remove from the active view.
    Active = sets:del_element(Peer, Active0),

    %% Add to the passive view.
    Passive = sets:del_element(Peer, Passive0),

    State#state{active=Active, passive=Passive}.

%% @private
myself() ->
    Port = partisan_config:get(peer_port, ?PEER_PORT),
    IPAddress = partisan_config:get(peer_ip, ?PEER_IP),
    {node(), IPAddress, Port}.

%% @private
arwl() ->
    ?ARWL.

%% @private
prwl() ->
    ?PRWL.

%% @private
remove_from_passive_view(Peer, Passive) ->
    sets:del_element(Peer, Passive).

%% @private
is_in_passive_view(Peer, Passive) ->
    sets:is_element(Peer, Passive).

%% @private
is_pending(Peer, Pending) ->
    sets:is_element(Peer, Pending).

%% @private
add_to_pending(Peer, Pending) ->
    sets:add_element(Peer, Pending).

%% @private
remove_from_pending(Peer, Pending) ->
    sets:del_element(Peer, Pending).

%% @private
is_in_active_view(Peer, Active) ->
    sets:is_element(Peer, Active).

%% @private
add_to_suspected(Peer, Suspected) ->
    sets:add_element(Peer, Suspected).

%% @private
remove_from_suspected(Peer, Suspected) ->
    sets:del_element(Peer, Suspected).

%% @private
is_empty(View) ->
    sets:size(View) =:= 0.

%% @private
is_not_empty(View) ->
    sets:size(View) > 0.

%% @private
is_replacement_candidate(Peer, Passive, Suspected) ->
    is_in_passive_view(Peer, Passive) andalso is_not_empty(Suspected).

%% @private
perform_join(Peer, #state{suspected=Suspected0,
                          connections=Connections}=State0) ->
    %% Add to active view.
    #state{active=Active} = State = add_to_active_view(Peer, State0),

    %% Remove from suspected.
    Suspected = remove_from_suspected(Peer, Suspected0),

    %% Random walk for forward join.
    Peers = members(Active) -- [myself()],

    lists:foreach(fun(P) ->
                do_send_message(P,
                                {forward_join, Peer, arwl(), myself()},
                                Connections)
        end, Peers),

    %% Return.
    State#state{suspected=Suspected}.

%% @private
send_neighbor(Peer, #state{active=Active0, connections=Connections}=State) ->
    Priority = case sets:size(Active0) of
        0 ->
            high;
        _ ->
            low
    end,

    do_send_message(Peer,
                    {neighbor, Peer, Priority, myself()},
                    Connections),

    State.

%% @private
neighbor_acceptable(Priority, #state{active=Active}) ->
    Priority =:= high orelse not is_full({active, Active}).

%% @private
k_active() ->
    3.

%% @private
k_passive() ->
    4.

%% @private
schedule_passive_view_maintenance() ->
    erlang:send_after(?PASSIVE_VIEW_MAINTENANCE_INTERVAL,
                      ?MODULE,
                      passive_view_maintenance).

%% @reference http://stackoverflow.com/questions/8817171/shuffling-elements-in-a-list-randomly-re-arrange-list-elements/8820501#8820501
shuffle(L) ->
    [X || {_, X} <- lists:sort([{random:uniform(), N} || N <- L])].

%% @private
merge_exchange(Exchange, #state{active=Active, passive=Passive0}=State) ->
    %% Remove ourself and active set members from the exchange.
    ToAdd = Exchange -- ([myself()] ++ members(Active)),

    %% Add to passive set.
    Passive = lists:foldl(fun(X, P) ->
        add_to_passive_view(X, P)
                end, Passive0, ToAdd),

    %% Return new state.
    State#state{passive=Passive}.

%% @private
notify(#state{active=Active}) ->
    partisan_peer_service_events:update(Active).
