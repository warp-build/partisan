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

%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-module(partisan_peer_service_client).
-author("Christopher S. Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(gen_server).


-include("partisan.hrl").
-include("partisan_logger.hrl").
-include("partisan_peer_socket.hrl").

-record(state, {
    socket          ::  partisan_peer_socket:t(),
    listen_addr     ::  partisan:listen_addr(),
    channel         ::  partisan:channel(),
    channel_opts    ::  partisan:channel_opts(),
    encoding_opts   ::  list(),
    from            ::  pid(),
    peer            ::  partisan:node_spec()
}).

-type state() :: #state{}.

%% Macros.
-define(TIMEOUT, 1000).

%% API
-export([start_link/5]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).



%% =============================================================================
%% API
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @doc Start and link to calling process.
%% If the process is started and can get a connection it returns `{ok, pid()}'.
%% Otherwise if it fails with `{error, Reason :: any()}'.
%% @end
%% -----------------------------------------------------------------------------
-spec start_link(
    Peer :: partisan:node_spec(),
    ListenAddr :: partisan:listen_addr(),
    Channel :: partisan:channel(),
    ChannelOpts :: partisan:channel_opts(),
    From :: pid()) ->
    {ok, pid()} | ignore | {error, Reason :: any()}.

start_link(Peer, ListenAddr, Channel, ChannelOpts, From) ->
    gen_server:start_link(
        ?MODULE, [Peer, ListenAddr, Channel, ChannelOpts, From], []
    ).



%% =============================================================================
%% GEN_SERVER CALLBACKS
%% =============================================================================




-spec init(Args :: list()) -> {ok, state()} | {stop, Reason :: any()}.

init([Peer, ListenAddr, Channel, ChannelOpts, From]) ->
    case connect(ListenAddr, Channel, ChannelOpts) of
        {ok, Socket} ->
            %% For debugging, store information in the process dictionary.
            put({?MODULE, from}, From),
            put({?MODULE, listen_addr}, ListenAddr),
            put({?MODULE, channel}, Channel),
            put({?MODULE, channel_opts}, ChannelOpts),
            put({?MODULE, peer}, Peer),
            put({?MODULE, egress_delay}, partisan_config:get(egress_delay, 0)),

            EncodeOpts =
                case maps:get(compression, ChannelOpts, false) of
                    true ->
                        [compressed];
                    N when N >= 0, N =< 9 ->
                        [{compressed, N}];
                    _ ->
                        []
                end,

            State = #state{
                from = From,
                listen_addr = ListenAddr,
                channel = Channel,
                channel_opts = ChannelOpts,
                encoding_opts = EncodeOpts,
                socket = Socket,
                peer = Peer
            },
            {ok, State};

        {error, Reason} ->
            ?LOG_TRACE(
                "Pid ~p is unable to connect to ~p due to ~p",
                [self(), Peer, Reason]
            ),
            %% We use shutdown to avoid a crash report
            {stop, normal}
    end.


-spec handle_call(term(), {pid(), term()}, state()) ->
    {reply, term(), state()}.

handle_call({send_message, Message}, _From, #state{} = State) ->
    case get({?MODULE, egress_delay}) of
        0 ->
            ok;
        Other ->
            timer:sleep(Other)
    end,

    Data = partisan_util:encode(Message, State#state.encoding_opts),

    case partisan_peer_socket:send(State#state.socket, Data) of
        ok ->
            ?LOG_TRACE("Dispatched message: ~p", [Message]),
            {reply, ok, State};
        Error ->
            ?LOG_DEBUG("Message ~p failed to send: ~p", [Message, Error]),
            {reply, Error, State}
    end;

handle_call(Event, _From, State) ->
    ?LOG_WARNING(#{description => "Unhandled call event", event => Event}),
    {reply, ok, State}.


-spec handle_cast(term(), state()) -> {noreply, state()}.

handle_cast({send_message, Message}, #state{} = State) ->
    ?LOG_TRACE("Received cast: ~p", [Message]),

    case get({?MODULE, egress_delay}) of
        0 ->
            ok;
        Other ->
            timer:sleep(Other)
    end,

    Data = partisan_util:encode(Message, State#state.encoding_opts),

    case partisan_peer_socket:send(State#state.socket, Data) of
        ok ->
            ?LOG_TRACE("Dispatched message: ~p", [Message]),
            ok;
        Error ->
            ?LOG_INFO(#{
                description => "Failed to send message",
                message => Message,
                error => Error
            })
    end,
    {noreply, State};

handle_cast(Event, State) ->
    ?LOG_WARNING(#{description => "Unhandled cast event", event => Event}),
    {noreply, State}.


-spec handle_info(term(), state()) ->
    {noreply, state()} | {stop, normal, state()}.

handle_info({Tag, _Socket, Data}, State0)
when ?DATA_MSG(Tag), is_binary(Data) ->
    Msg = binary_to_term(Data),

    ?LOG_TRACE("Received info message at ~p: ~p", [self(), Msg]),

    handle_message(Msg, State0);

handle_info({Tag, _Socket}, #state{} = State) when ?CLOSED_MSG(Tag) ->
    ?LOG_TRACE(
        "Connection to ~p has been closed for pid ~p",
        [State#state.peer, self()]
    ),

    {stop, normal, State};

handle_info(Event, State) ->
    ?LOG_WARNING(#{description => "Unhandled info event", event => Event}),
    {noreply, State}.


-spec terminate(term(), state()) -> term().

terminate(Reason, #state{} = State) ->
    ?LOG_TRACE("Process ~p terminating for reason ~p...", [self(), Reason]),
    ok = partisan_peer_socket:close(State#state.socket),
    ok.


-spec code_change(term() | {down, term()}, state(), term()) ->
    {ok, state()}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================



%% @doc Test harness specific.
%%
%% If we're running a local test, we have to use the same IP address for
%% every bind operation, but a different port instead of the standard
%% port.
%%
connect(Node, Channel, ChannelOpts)
when is_atom(Node), is_atom(Channel), is_map(ChannelOpts) ->
    %% Used for testing when connect_disterl is enabled
    partisan_config:get(connect_disterl, false)
        orelse error(disterl_not_enabled),

    case rpc:call(Node, partisan_config, get, [listen_addrs]) of
        {badrpc, Reason} ->
            {error, Reason};

        [] ->
            {error, no_listen_addr};

        [ListenAddr|_] ->
            %% Use first address
            connect(ListenAddr, Channel, ChannelOpts)
    end;

connect(#{ip := Address, port := Port}, Channel, ChannelOpts)
when is_atom(Channel), is_map(ChannelOpts) ->
    SocketOpts = [
        binary,
        {active, true},
        {packet, 4},
        {keepalive, true}
    ],

    Opts = [{monotonic, maps:get(monotonic, ChannelOpts, false)}],

    Result = partisan_peer_socket:connect(
        Address, Port, SocketOpts, ?TIMEOUT, Opts
    ),

    case Result of
        {ok, Socket} ->
            {ok, Socket};

        {error, Error} ->
            %% TODO LOG HERE
            {error, Error}
    end.


%% @private
handle_message({state, Tag, LocalState}, #state{} = State) ->
    #state{
        peer = Peer,
        channel = Channel,
        from = From
    } = State,

    %% Notify peer service manager we are done.
    case LocalState of
        %% TODO: Anything using a three tuple will be caught here.
        %% TODO: This format is specific to the HyParView manager.
        {state, _Active, Epoch} ->
            From ! {connected, Peer, Channel, Tag, Epoch, LocalState};
        _Other ->
            From ! {connected, Peer, Channel, Tag, LocalState}
    end,

    {noreply, State};

handle_message({hello, Node}, #state{peer = #{name := Node}} = State) ->
    Socket = State#state.socket,
    Message = term_to_binary({hello, partisan:node(), State#state.channel}),

    case partisan_peer_socket:send(Socket, Message) of
        ok ->
            ok;
        Error ->
            ?LOG_INFO(#{
                description => "Failed to send hello message to node",
                node => Node,
                error => Error
            })
    end,
    {noreply, State};

handle_message({hello, A}, #state{peer = #{name := B}} = State)
when A =/= B ->
    %% Peer isn't who it should be, abort.
    ?LOG_ERROR(#{
        description => "Unexpected peer, aborting",
        got => A,
        expected => B
    }),
    {stop, {unexpected_peer, A, B}, State};

handle_message(Message, State) ->
    ?LOG_WARNING(#{
        description => "Received invalid message",
        message => Message
    }),
    {stop, normal, State}.


