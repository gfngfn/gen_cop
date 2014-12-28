%% @copyright 2014, Takeru Ohta <phjgt308@gmail.com>
%%
%% @doc Protocol Session Process
%% @private
%%
-module(gen_cop_server).

%%----------------------------------------------------------------------------------------------------------------------
%% Exported API
%%----------------------------------------------------------------------------------------------------------------------
-export([start/1]).

%%----------------------------------------------------------------------------------------------------------------------
%% Internal API
%%----------------------------------------------------------------------------------------------------------------------
-export([init/5]).

%%----------------------------------------------------------------------------------------------------------------------
%% 'sys' Callback API
%%----------------------------------------------------------------------------------------------------------------------
-export([system_continue/3, system_terminate/4, system_code_change/4]).

%%----------------------------------------------------------------------------------------------------------------------
%% Records & Types
%%----------------------------------------------------------------------------------------------------------------------
-record(state,
        {
          context :: gen_cop_context:context()
        }).

-type sync_fun() :: fun ((Result::term()) -> any()). % TODO: doc

-type start_arg() :: {inet:socket(), gen_cop:codec(), [gen_cop_handler:uninitialized_handler()], gen_cop:start_opts()}.

%%----------------------------------------------------------------------------------------------------------------------
%% Exported Functions
%%----------------------------------------------------------------------------------------------------------------------
%% @see gen_cop:start/4
-spec start(start_arg()) -> {ok, pid()} | {error, gen_cop:start_err()}.
start(StartArg = {Socket, _, _, Options}) ->
    Name = proplists:get_value(name, Options),
    case Name =:= undefined orelse where(Name) of
        Pid when is_pid(Pid) -> {error, {already_started, Pid}};
        _                    ->
            ok = inet:setopts(Socket, [{active, false}, binary]),
            Ref = make_ref(),

            Pid = spawn_session(Ref, StartArg),
            _ = proplists:get_value(ack_fun, Options) =:= undefined andalso
                begin
                    ok = gen_tcp:controlling_process(Socket, Pid),
                    Pid ! Ref
                end,

            case proplists:get_value(async, Options, false) of
                true  -> {ok, Pid};
                false -> wait_start_result(Pid, Ref, Options)
            end
    end.

-define(LOCATION, [{module, ?MODULE}, {line, ?LINE}, {pid, self()}]).

-define(MAKE_EX_REASON(ExClass, ExReason, MFArgs),
        {'EXIT', [{exception, ExClass, ExReason},
                  {trace, erlang:get_stacktrace()},
                  {location, ?LOCATION},
                  {mfargs, MFArgs}]}).

-define(FUNCALL_ERROR(Reason, MFArgs),
        {funcall_error, Reason, [{mfargs, MFArgs}, {location, ?LOCATION}]}).

%%----------------------------------------------------------------------------------------------------------------------
%% Internal Functions
%%----------------------------------------------------------------------------------------------------------------------
-spec spawn_session(reference(), start_arg()) -> pid(). % XXX: name
spawn_session(Ref, StartArg = {_, _, _, Options}) ->
    Name = proplists:get_value(name, Options),
    Parent = self(),
    AckFun = proplists:get_value(ack_fun, Options, fun () -> receive Ref -> ok end end),
    SyncFun =
        case proplists:get_value(async, Options, false) of
            true  -> fun (_) -> ok end;
            false -> fun (Result) -> Parent ! {Ref, Result}, receive Ref -> ok end end
        end,
    SpawnOptions0 = proplists:get_value(spawn_opt, Options, []),
    SpawnOptions1 =
        case proplists:get_value(link, Options, false) of
            false -> SpawnOptions0;
            true  -> [link | SpawnOptions0]
        end,
    proc_lib:spawn_opt(?MODULE, init, [Parent, Name, AckFun, SyncFun, StartArg], SpawnOptions1).

-spec wait_start_result(pid(), reference(), gen_cop:start_opts()) -> {ok, pid()} | {error, Reason} when Reason :: timeout | term().
wait_start_result(Pid, Ref, Options) ->
    Timeout = proplists:get_value(timeout, Options, infinity),
    Monitor = monitor(process, Pid),
    receive
        {Ref, Result} ->
            _ = demonitor(Monitor, [flush]),
            _ = Pid ! Ref,
            Result;
        {'DOWN', Monitor, _, _, Reason} ->
            {error, Reason}
    after Timeout ->
            _ = unlink(Pid),
            _ = exit(Pid, kill),
            _ = receive {'EXIT', Pid, _} -> ok after 0 -> ok end,
            _ = demonitor(Monitor, [flush]),
            {error, timeout}
    end.

-spec init(pid(), gen_cop:otp_name() | undefined, gen_cop:ack_fun(), sync_fun(), start_arg()) -> no_return().
init(Parent, Name, AckFun, SyncFun, StartArg) when Name =/= undefined ->
    case name_register(Name) of
        {false, Pid} -> SyncFun({error, {already_started, Pid}});
        true         -> init(Parent, undefined, AckFun, SyncFun, StartArg)
    end;
init(Parent, _, AckFun, SyncFun, {Socket, Codec, Handlers, Options}) ->
    _ = AckFun(),
    case gen_cop_context:init(Socket, Codec, Handlers) of
        {stop, Reason} ->
            _ = SyncFun({error, Reason}),
            exit(Reason);
        {ok, Context} ->
            _  = SyncFun({ok, self()}),
            ok = inet:setopts(Socket, [{active, once}]),
            State = #state{context = Context},
            loop(State, Parent, sys:debug_options(proplists:get_value(debug, Options, [])))
    end.

loop(State0, Parent, Debug) ->
    %% TODO: exception handling (if need)
    Result =
        receive
            {tcp, _, Bin} ->
                flush_send_queue_if_need(handle_recv(Bin, State0));
            {call, Request, From} -> % XXX:
                flush_send_queue_if_need(handle_call(Request, From, State0));
            {cast, Request} -> % XXX:
                flush_send_queue_if_need(handle_cast(Request, State0));

            {tcp_closed, _}           -> {error, {shutdown, tcp_closed}, State0};
            {tcp_error, _, TcpReason} -> {error, {shutdown, {tcp_error, TcpReason}}, State0};

            %% sys releated messages
            {system, _, _} = SystemMessage -> SystemMessage;
            %% TODO: {From, Tag, get_modules} -> _ = ?SYSTEM_REPLY(From, Tag, get_modules(State)), State;

            Msg ->
                flush_send_queue_if_need(handle_info(Msg, State0))
        end,
    case Result of
        {ok, State1}              -> loop(State1, Parent, Debug);
        {error, Reason, State1}   -> terminate(Reason, State1);
        {system, From2, Request2} -> sys:handle_system_msg(Request2, From2, Parent, ?MODULE, Debug, State0)
    end.

flush_send_queue_if_need({ok, State}) ->
    flush_send_queue(State);
flush_send_queue_if_need(Other) ->
    Other.

flush_send_queue(State0) ->
    %% TODO: exception handling
    case gen_cop_context:flush_send_queue(State0#state.context) of
        {error, Reason, Context} -> {error, Reason, State0#state{context = Context}};
        {ok, IoData, Context}    ->
            State1 = State0#state{context = Context},
            case gen_tcp:send(gen_cop_context:get_socket(Context), IoData) of
                {error, Reason} -> {error, Reason, State1};
                ok              -> {ok, State1}
            end
    end.

handle_recv(Bin, State0) ->
    case gen_cop_context:recv(Bin, State0#state.context) of
        {stop, Reason, Context} -> {error, Reason, State0#state{context = Context}};
        {ok, Context}           ->
            ok = inet:setopts(gen_cop_context:get_socket(Context), [{active, once}]), % TODO: error handling
            {ok, State0#state{context = Context}}
    end.

handle_call(Request, From, State) ->
    case gen_cop_context:handle_call(Request, From, State#state.context) of
        {stop, Reason, Context} -> {error, Reason, State#state{context = Context}};
        {ok, Context}           -> {ok, State#state{context = Context}}
    end.

handle_cast(Request, State) ->
    case gen_cop_context:handle_cast(Request, State#state.context) of
        {stop, Reason, Context} -> {error, Reason, State#state{context = Context}};
        {ok, Context}           -> {ok, State#state{context = Context}}
    end.

%% TODO: Request => Info
handle_info(Info, State) ->
    case gen_cop_context:handle_cast(Info, State#state.context) of
        {stop, Reason, Context} -> {error, Reason, State#state{context = Context}};
        {ok, Context}           -> {ok, State#state{context = Context}}
    end.

terminate(Reason, State0) ->
    _ = gen_cop_context:terminate(Reason, State0#state.context),
    exit(Reason).

where({global, Name}) -> global:whereis_name(Name);
where({via, Module, Name}) -> Module:whereis_name(Name);
where({local, Name})  -> whereis(Name).

name_register({local, Name} = LN) ->
    try register(Name, self()) of
        true -> true
    catch
        error:_ ->
            {false, where(LN)}
    end;
name_register({global, Name} = GN) ->
    case global:register_name(Name, self()) of
        yes -> true;
        no -> {false, where(GN)}
    end;
name_register({via, Module, Name} = GN) ->
    case Module:register_name(Name, self()) of
        yes ->
            true;
        no ->
            {false, where(GN)}
    end.

%%----------------------------------------------------------------------------------------------------------------------
%% 'sys' Callback Functions
%%----------------------------------------------------------------------------------------------------------------------
%% @private
system_continue(Parent, Debug, State) ->
    loop(State, Parent, Debug).

%% @private
%%-spec system_terminate(any(), pid(), any(), session()) -> no_return(). % dialyzerの警告抑制のためのspec
system_terminate(Reason, _Parent, _Debug, State) ->
    terminate(Reason, State).

%% @private
system_code_change(State, _Module, _OldVsn, _Extra) ->
    %% TODO:
    %% Handlers = [case Module =:= HMod of
    %%                 true ->
    %%                     {ok, HState1} = HMod:codec_hange(OldVsn, HState0, Extra),
    %%                     {HMod, HState1};
    %%                 false ->
    %%                     {HMod, HState0}
    %%             end || {HMod, HState0} <- State#state.handlers],
    %% {ok, State#state{handlers = Handlers}}.
    {ok, State}.