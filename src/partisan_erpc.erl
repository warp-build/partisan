%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2020-2021. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%
%% Author: Rickard Green
%%

%% -----------------------------------------------------------------------------
%% @doc This module is an adaptation of Erlang `erpc' module.
%%
%% It replaces all instances of `erlang:send/2` and `erlang:monitor/2` with
%% their Partisan counterparts.
%%
%% It maintains the `erpc' API with the following exceptions:
%%
%% <ul>
%% </ul>
%%
%% TODO
%% - Channels
%%
%% <strong>NOTICE:</strong>
%% At the moment this only works for `partisan_pluggable_peer_service_manager'.
%% @end
%% -----------------------------------------------------------------------------
%% -
-module(partisan_erpc).

%% Exported API

-export([call/2,
         call/3,
         call/4,
         call/5,
         cast/2,
     cast/4,
         send_request/2,
         send_request/4,
         receive_response/1,
         receive_response/2,
         wait_response/1,
         wait_response/2,
         check_response/2,
         multicall/2,
         multicall/3,
         multicall/4,
     multicall/5,
         multicast/2,
     multicast/4]).

-export_type([request_id/0]).

%% Internal exports (also used by the 'rpc' module)

-export([execute_call/4,
         execute_call/3,
         execute_cast/3,
         is_arg_error/4,
         trim_stack/4,
         call_result/4]).

%%------------------------------------------------------------------------

-compile({inline,[{result,4}]}). %% Nicer error stack trace...

-define(MAX_INT_TIMEOUT, 4294967295).
-define(TIMEOUT_TYPE, 0..?MAX_INT_TIMEOUT | 'infinity').
-define(IS_VALID_TMO_INT(TI_), (is_integer(TI_)
                                andalso (0 =< TI_)
                                andalso (TI_ =< ?MAX_INT_TIMEOUT))).
-define(IS_VALID_TMO(T_), ((T_ == infinity) orelse ?IS_VALID_TMO_INT(T_))).

%%------------------------------------------------------------------------
%% Exported API
%%------------------------------------------------------------------------

-spec call(Node, Fun) -> Result when
      Node :: node(),
      Fun :: function(),
      Result :: term().

call(N, Fun) ->
    call(N, Fun, infinity).

-spec call(Node, Fun, Timeout) -> Result when
      Node :: node(),
      Fun :: function(),
      Timeout :: ?TIMEOUT_TYPE,
      Result :: term().

call(N, Fun, Timeout) when is_function(Fun, 0) ->
    call(N, erlang, apply, [Fun, []], Timeout);
call(_N, _Fun, _Timeout) ->
    error({?MODULE, badarg}).

-spec call(Node, Module, Function, Args) -> Result when
      Node :: node(),
      Module :: atom(),
      Function :: atom(),
      Args :: [term()],
      Result :: term().

call(N, M, F, A) ->
    call(N, M, F, A, infinity).

-dialyzer([{nowarn_function, call/5}, no_return]).

-spec call(Node, Module, Function, Args, Timeout) -> Result when
      Node :: node(),
      Module :: atom(),
      Function :: atom(),
      Args :: [term()],
      Timeout :: ?TIMEOUT_TYPE,
      Result :: term().

call(N, M, F, A, T) when is_atom(M),
                         is_atom(F),
                         is_list(A),
                         ?IS_VALID_TMO(T) ->
    %% Optimize local call
    case N == partisan:node() andalso T == infinity of
        true ->
            try
                {return, Return} = execute_call(M,F,A),
                Return
            catch
                exit:Reason ->
                    exit({exception, Reason});
                error:Reason:Stack ->
                    case is_arg_error(Reason, M, F, A) of
                        true ->
                            error({?MODULE, Reason});
                        false ->
                            ErpcStack = trim_stack(Stack, M, F, A),
                            error({exception, Reason, ErpcStack})
                    end
            end;
        false ->
            Res =
                case N =:= partisan:node() of
                    true ->
                        make_ref();
                    false ->
                        partisan:make_ref()
                end,
            ReqId = spawn_request(N, ?MODULE, execute_call, [Res, M, F, A],
                                  [{reply, error_only}, monitor]),
            receive
                {spawn_reply, ReqId, error, Reason} ->
                    result(spawn_reply, ReqId, Res, Reason);
                {'DOWN', ReqId, process, _Pid, Reason} ->
                    result(down, ReqId, Res, Reason)
            after T ->
                    result(timeout, ReqId, Res, undefined)
            end
    end;
call(_N, _M, _F, _A, _T) ->
    error({?MODULE, badarg}).

%% Asynchronous call

-opaque request_id() :: {partisan:any_reference(), partisan:any_reference()}.

-spec send_request(Node, Fun) -> RequestId when
      Node :: node(),
      Fun :: function(),
      RequestId :: request_id().

send_request(N, F) when is_function(F, 0) ->
    send_request(N, erlang, apply, [F, []]);
send_request(_N, _F) ->
    error({?MODULE, badarg}).

-spec send_request(Node, Module, Function, Args) -> RequestId when
      Node :: node(),
      Module :: atom(),
      Function :: atom(),
      Args :: [term()],
      RequestId :: request_id().

send_request(N, M, F, A) when is_atom(N),
                              is_atom(M),
                              is_atom(F),
                              is_list(A) ->
    Res =
        case N =:= partisan:node() of
            true ->
                make_ref();
            false ->
                partisan:make_ref()
        end,
    ReqId = spawn_request(N, ?MODULE, execute_call, [Res, M, F, A],
                          [{reply, error_only}, monitor]),
    {Res, ReqId};
send_request(_N, _M, _F, _A) ->
    error({?MODULE, badarg}).

-spec receive_response(RequestId) -> Result when
      RequestId :: request_id(),
      Result :: term().

receive_response({Res, ReqId} = RId) when is_reference(Res),
                                          is_reference(ReqId) ->
    receive_response(RId, infinity);
receive_response(_) ->
    error({?MODULE, badarg}).

-dialyzer([{nowarn_function, receive_response/2}, no_return]).

-spec receive_response(RequestId, Timeout) -> Result when
      RequestId :: request_id(),
      Timeout :: ?TIMEOUT_TYPE,
      Result :: term().

receive_response({Res, ReqId}, Tmo) when ?IS_VALID_TMO(Tmo) ->
    partisan:is_reference(Res) andalso partisan:is_reference(ReqId)
        orelse error({?MODULE, badarg}),

    receive
        {spawn_reply, ReqId, error, Reason} ->
            result(spawn_reply, ReqId, Res, Reason);
        {'DOWN', ReqId, process, _Pid, Reason} ->
            result(down, ReqId, Res, Reason)
    after Tmo ->
            result(timeout, ReqId, Res, undefined)
    end;
receive_response(_, _) ->
    error({?MODULE, badarg}).

-spec wait_response(RequestId) -> {'response', Result} | 'no_response' when
      RequestId :: request_id(),
      Result :: term().

wait_response({Res, ReqId} = RId) ->
    partisan:is_reference(Res) andalso partisan:is_reference(ReqId)
        orelse error(function_clause),
    wait_response(RId, 0).
    
-dialyzer([{nowarn_function, wait_response/2}, no_return]).

-spec wait_response(RequestId, WaitTime) ->
          {'response', Result} | 'no_response' when
      RequestId :: request_id(),
      WaitTime :: ?TIMEOUT_TYPE,
      Result :: term().

wait_response({Res, ReqId}, WT) when ?IS_VALID_TMO(WT) ->
    partisan:is_reference(Res) andalso partisan:is_reference(ReqId)
        orelse error({?MODULE, badarg}),

    receive
        {spawn_reply, ReqId, error, Reason} ->
            result(spawn_reply, ReqId, Res, Reason);
        {'DOWN', ReqId, process, _Pid, Reason} ->
            {response, result(down, ReqId, Res, Reason)}
    after WT ->
            no_response
    end;
wait_response(_, _) ->
    error({?MODULE, badarg}).

-dialyzer([{nowarn_function, check_response/2}, no_return]).

-spec check_response(Message, RequestId) ->
          {'response', Result} | 'no_response' when
      Message :: term(),
      RequestId :: request_id(),
      Result :: term().

check_response({spawn_reply, ReqId, error, Reason},{Res, ReqId}) ->
    partisan:is_reference(Res) andalso partisan:is_reference(ReqId)
        orelse error({?MODULE, badarg}),
    result(spawn_reply, ReqId, Res, Reason);
check_response({'DOWN', ReqId, process, _Pid, Reason},{Res, ReqId}) ->
    partisan:is_reference(Res) andalso partisan:is_reference(ReqId)
        orelse error({?MODULE, badarg}),
    {response, result(down, ReqId, Res, Reason)};
check_response(_Msg, {Res, ReqId}) ->
    partisan:is_reference(Res) andalso partisan:is_reference(ReqId)
        orelse error({?MODULE, badarg}),
    no_response;
check_response(_, _) ->
    error({?MODULE, badarg}).

-type stack_item() ::
        {Module :: atom(),
         Function :: atom(),
         Arity :: arity() | (Args :: [term()]),
         Location :: [{file, Filename :: string()} |
                      {line, Line :: pos_integer()}]}.

-type caught_call_exception() ::
        {throw, Throw :: term()}
      | {exit, {exception, Reason :: term()}}
      | {error, {exception, Reason :: term(), StackTrace :: [stack_item()]}}
      | {exit, {signal, Reason :: term()}}
      | {error, {?MODULE, Reason :: term()}}.


-spec multicall(Nodes, Fun) -> Result when
      Nodes :: [atom()],
      Fun :: function(),
      Result :: term().

multicall(Ns, Fun) ->
    multicall(Ns, Fun, infinity).

-spec multicall(Nodes, Fun, Timeout) -> Result when
      Nodes :: [atom()],
      Fun :: function(),
      Timeout :: ?TIMEOUT_TYPE,
      Result :: term().

multicall(Ns, Fun, Timeout) when is_function(Fun, 0) ->
    multicall(Ns, erlang, apply, [Fun, []], Timeout);
multicall(_Ns, _Fun, _Timeout) ->
    error({?MODULE, badarg}).

-spec multicall(Nodes, Module, Function, Args) -> Result when
      Nodes :: [atom()],
      Module :: atom(),
      Function :: atom(),
      Args :: [term()],
      Result :: [{ok, ReturnValue :: term()} | caught_call_exception()].

multicall(Ns, M, F, A) ->
    multicall(Ns, M, F, A, infinity).

-spec multicall(Nodes, Module, Function, Args, Timeout) -> Result when
      Nodes :: [atom()],
      Module :: atom(),
      Function :: atom(),
      Args :: [term()],
      Timeout :: ?TIMEOUT_TYPE,
      Result :: [{ok, ReturnValue :: term()} | caught_call_exception()].

multicall(Ns, M, F, A, T) ->
    try
        true = is_atom(M),
        true = is_atom(F),
        true = is_list(A),
        Tag = make_ref(),
        SendState = mcall_send_requests(Tag, Ns, M, F, A, T),
        mcall_receive_replies(Tag, SendState)
    catch
        error:NotIErr when NotIErr /= internal_error ->
            error({?MODULE, badarg})
    end.

-spec multicast(Nodes, Fun) -> 'ok' when
      Nodes :: [node()],
      Fun :: function().

multicast(N, Fun) ->
    multicast(N, erlang, apply, [Fun, []]).

-spec multicast(Nodes, Module, Function, Args) -> 'ok' when
      Nodes :: [node()],
      Module :: atom(),
      Function :: atom(),
      Args :: [term()].

multicast(Nodes, Mod, Fun, Args) ->
    try
        true = is_atom(Mod),
        true = is_atom(Fun),
        true = is_list(Args),
        multicast_send_requests(Nodes, Mod, Fun, Args)
    catch
        error:_ ->
            error({?MODULE, badarg})
    end.

multicast_send_requests([], _Mod, _Fun, _Args) ->
    ok;
multicast_send_requests([Node|Nodes], Mod, Fun, Args) ->
    _ = spawn_request(Node, ?MODULE, execute_cast, [Mod, Fun, Args],
                      [{reply, no}]),
    multicast_send_requests(Nodes, Mod, Fun, Args).

-spec cast(Node, Fun) -> 'ok' when
      Node :: node(),
      Fun :: function().

cast(N, Fun) ->
    cast(N, erlang, apply, [Fun, []]).

-spec cast(Node, Module, Function, Args) -> 'ok' when
      Node :: node(),
      Module :: atom(),
      Function :: atom(),
      Args :: [term()].

cast(Node, Mod, Fun, Args) when is_atom(Node),
                                is_atom(Mod),
                                is_atom(Fun),
                                is_list(Args) ->
    _ = spawn_request(Node, ?MODULE, execute_cast, [Mod, Fun, Args],
                      [{reply, no}]),
    ok;
cast(_Node, _Mod, _Fun, _Args) ->
    error({?MODULE, badarg}).

%%------------------------------------------------------------------------
%% Exported internals
%%------------------------------------------------------------------------

%% Note that most of these are used by 'rpc' as well...

execute_call(Ref, M, F, A) ->
    Reply = try
                {Ref, return, apply(M, F, A)}
            catch
                throw:Reason ->
                    {Ref, throw, Reason};
                exit:Reason ->
                    {Ref, exit, Reason};
                error:Reason:Stack ->
                    case is_arg_error(Reason, M, F, A) of
                        true ->
                            {Ref, error, {?MODULE, Reason}};
                        false ->
                            ErpcStack = trim_stack(Stack, M, F, A),
                            {Ref, error, Reason, ErpcStack}
                    end
            end,
    exit(Reply).

execute_call(M,F,A) ->
    {return, apply(M, F, A)}.

execute_cast(M, F, A) ->
    try
        apply(M, F, A)
    catch
        error:Reason:Stack ->
            %% Produce error reports with error
            %% exceptions produced for calls...
            case is_arg_error(Reason, M, F, A) of
                true ->
                    error({?MODULE, Reason});
                false ->
                    ErpcStack = trim_stack(Stack, M, F, A),
                    error({exception, {Reason, ErpcStack}})
            end
    end.

call_result(Type, ReqId, Res, Reason) ->
    result(Type, ReqId, Res, Reason).

is_arg_error(system_limit, _M, _F, A) ->
    try
        apply(?MODULE, nonexisting, A),
        false
    catch
        error:system_limit -> true;
        _:_ -> false
    end;
is_arg_error(_R, _M, _F, _A) ->
    false.

-define(IS_CUT_FRAME(F),
        ((element(1, (F)) == ?MODULE)
         andalso ((element(2, (F)) == execute_call)
                  orelse ((element(2, (F)) == execute_cast))))).

trim_stack([CF | _], M, F, A) when ?IS_CUT_FRAME(CF) ->
    [{M, F, A, []}];
trim_stack([{M, F, A, _} = SF, CF | _], M, F, A) when ?IS_CUT_FRAME(CF) ->
    [SF];
trim_stack(S, M, F, A) ->
    try
        trim_stack_aux(S, M, F, A)
    catch
        throw:use_all -> S
    end.

%%------------------------------------------------------------------------
%% Internals
%%------------------------------------------------------------------------

trim_stack_aux([], _M, _F, _A) ->
    throw(use_all);
trim_stack_aux([{M, F, AL, _} = SF, CF | _], M, F, A) when ?IS_CUT_FRAME(CF),
                                                            AL == length(A) ->
    [SF];
trim_stack_aux([CF | _], M, F, A) when ?IS_CUT_FRAME(CF) ->
    try
        [{M, F, length(A), []}]
    catch
        _:_ ->
            []
    end;
trim_stack_aux([SF|SFs], M, F, A) ->
    [SF|trim_stack_aux(SFs, M, F, A)].

call_abandon(ReqId) ->
    case spawn_request_abandon(ReqId) of
        true -> true;
        false -> erlang:demonitor(ReqId, [info])
    end.

-dialyzer([{nowarn_function, result/4}, no_return]).

-spec result('down', ReqId, Res, Reason) -> term() when
      ReqId :: partisan:any_reference(),
      Res :: partisan:any_reference(),
      Reason :: term();
                  ('spawn_reply', ReqId, Res, Reason) -> no_return() when
      ReqId :: partisan:any_reference(),
      Res :: partisan:any_reference(),
      Reason :: term();
                  ('timeout', ReqId, Res, Reason) -> term() when
      ReqId :: partisan:any_reference(),
      Res :: partisan:any_reference(),
      Reason :: term().

result(down, _ReqId, Res, {Res, return, Return}) ->
    Return;
result(down, _ReqId, Res, {Res, throw, Throw}) ->
    throw(Throw);
result(down, _ReqId, Res, {Res, exit, Exit}) ->
    exit({exception, Exit});
result(down, _ReqId, Res, {Res, error, Error, Stack}) ->
    error({exception, Error, Stack});
result(down, _ReqId, Res, {Res, error, {?MODULE, _} = ErpcErr}) ->
    error(ErpcErr);
result(down, _ReqId, _Res, noconnection) ->
    error({?MODULE, noconnection});
result(down, _ReqId, _Res, Reason) ->
    exit({signal, Reason});
result(spawn_reply, _ReqId, _Res, Reason) ->
    error({?MODULE, Reason});
result(timeout, ReqId, Res, _Reason) ->
    case call_abandon(ReqId) of
        true ->
            error({?MODULE, timeout});
        false ->
            %% Spawn error or DOWN has arrived. Return
            %% a result instead of a timeout since we
            %% just got the result...
            receive
                {spawn_reply, ReqId, error, Reason} ->
                    result(spawn_reply, ReqId, Res, Reason);
                {'DOWN', ReqId, process, _Pid, Reason} ->
                    result(down, ReqId, Res, Reason)
            after
                0 ->
                    %% Invalid request id...
                    error({?MODULE, badarg})
            end
    end.

deadline(infinity) ->
    infinity;
deadline(?MAX_INT_TIMEOUT) ->
    erlang:convert_time_unit(erlang:monotonic_time(millisecond)
                             + ?MAX_INT_TIMEOUT,
                             millisecond,
                             native);
deadline(T) when ?IS_VALID_TMO_INT(T) ->
    Now = erlang:monotonic_time(),
    NativeTmo = erlang:convert_time_unit(T, millisecond, native),
    Now + NativeTmo.

time_left(infinity) ->
    infinity;
time_left(expired) ->
    0;
time_left(Deadline) ->
    case Deadline - erlang:monotonic_time() of
        TimeLeft when TimeLeft =< 0 ->
            0;
        TimeLeft ->
            erlang:convert_time_unit(TimeLeft-1, native, millisecond) + 1
    end.

mcall_local_call(M, F, A) ->
    try
        {return, Return} = execute_call(M, F, A),
        {ok, Return}
    catch
        throw:Thrown ->
            {throw, Thrown};
        exit:Reason ->
            {exit, {exception, Reason}};
        error:Reason:Stack ->
            case is_arg_error(Reason, M, F, A) of
                true ->
                    {error, {?MODULE, Reason}};
                false ->
                    ErpcStack = trim_stack(Stack, M, F, A),
                    {error, {exception, Reason, ErpcStack}}
            end
    end.

mcall_send_request(T, N, M, F, A) when is_reference(T),
                                       is_atom(N),
                                       is_atom(M),
                                       is_atom(F),
                                       is_list(A) ->
    spawn_request(N, ?MODULE, execute_call, [T, M, F, A],
                  [{reply, error_only},
                   {reply_tag, T},
                   {monitor, [{tag, T}]}]).

mcall_send_requests(Tag, Ns, M, F, A, Tmo) ->
    DL = deadline(Tmo),
    mcall_send_requests(Tag, Ns, M, F, A, [], DL, undefined, 0).

mcall_send_requests(_Tag, [], M, F, A, RIDs, DL, local_call, NRs) ->
    %% Timeout infinity and call on local node wanted;
    %% execute local call in this process...
    LRes = mcall_local_call(M, F, A),
    {ok, RIDs, #{local_call => LRes}, NRs, DL};
mcall_send_requests(_Tag, [], _M, _F, _A, RIDs, DL, _LC, NRs) ->
    {ok, RIDs, #{}, NRs, DL};
mcall_send_requests(Tag, [N|Ns], M, F, A, RIDs, DL, LC, NRs) ->
    case N == partisan:node() andalso DL == infinity andalso LC == undefined of
        true ->
            mcall_send_requests(Tag, Ns, M, F, A, [local_call|RIDs],
                        infinity, local_call, NRs);
        false ->
            try mcall_send_request(Tag, N, M, F, A) of
                RID ->
                    mcall_send_requests(Tag, Ns, M, F, A, [RID|RIDs],
                                        DL, LC, NRs+1)
            catch
                _:_ ->
                    %% Bad argument... Abandon requests and cleanup
                    %% any responses by receiving replies with a zero
                    %% timeout and then fail...
                    {badarg, RIDs, #{}, NRs, expired}
            end
    end;
mcall_send_requests(_Tag, _Ns, _M, _F, _A, RIDs, _DL, _LC, NRs) ->
    %% Bad nodes list... Abandon requests and cleanup any responses
    %% by receiving replies with a zero timeout and then fail...
    {badarg, RIDs, #{}, NRs, expired}.

mcall_receive_replies(Tag, {SendRes, RIDs, Rpls, NRs, DL}) ->
    ResRpls = mcall_receive_replies(Tag, RIDs, Rpls, NRs, DL),
    if SendRes /= ok ->
            error(SendRes); %% Cleanup done; fail...
       true ->
            mcall_map_replies(RIDs, ResRpls, [])
    end.

mcall_receive_replies(_Tag, _ReqIds, Rpls, 0, _DL) ->
    Rpls;
mcall_receive_replies(Tag, ReqIDs, Rpls, NRs, DL) ->
    Tmo = time_left(DL),
    receive
        {Tag, ReqId, error, Reason} ->
            Res = mcall_result(spawn_reply, ReqId, Tag, Reason),
            mcall_receive_replies(Tag, ReqIDs, Rpls#{ReqId => Res},
                                  NRs-1, DL);
        {Tag, ReqId, process, _Pid, Reason} ->
            Res = mcall_result(down, ReqId, Tag, Reason),
            mcall_receive_replies(Tag, ReqIDs, Rpls#{ReqId => Res},
                                  NRs-1, DL)
    after Tmo ->
            if ReqIDs == [] ->
                    Rpls;
               true ->
                    NewNRs = mcall_abandon(Tag, ReqIDs, Rpls, NRs),
                    mcall_receive_replies(Tag, [], Rpls, NewNRs, expired)
            end
    end.

mcall_result(ResType, ReqId, Tag, ResultReason) ->
    try
        {ok, result(ResType, ReqId, Tag, ResultReason)}
    catch
        Class:Reason ->
            {Class, Reason}
    end.

mcall_abandon(_Tag, [], _Rpls, NRs) ->
    NRs;
mcall_abandon(Tag, [local_call | RIDs], Rpls, NRs) ->
    mcall_abandon(Tag, RIDs, Rpls, NRs);
mcall_abandon(Tag, [RID | RIDs], Rpls, NRs) ->
    NewNRs = case maps:is_key(RID, Rpls) of
                 true ->
                     NRs;
                 false ->
                     case call_abandon(RID) of
                         true -> NRs-1;
                         false -> NRs
                     end
             end,
    mcall_abandon(Tag, RIDs, Rpls, NewNRs).

mcall_map_replies([], _Rpls, Res) ->
    Res;
mcall_map_replies([RID|RIDs], Rpls, Res) ->
    Timeout = {error, {?MODULE, timeout}},
    mcall_map_replies(RIDs, Rpls, [maps:get(RID, Rpls, Timeout) | Res]).
    