%% @copyright 2014, Takeru Ohta <phjgt308@gmail.com>
%%
%% @doc Protocol Session Context
%% @private
-module(gen_cop_context).

%%----------------------------------------------------------------------------------------------------------------------
%% Exported API
%%----------------------------------------------------------------------------------------------------------------------
-export([init/3]).
-export([get_socket/1]).
-export([send/2]).
-export([recv/2]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([flush_send_queue/1]).

-export([ok/1, ok/2, ok/3]).
-export([stop/2, stop/3]).
-export([raise/3, raise/4]).

-export([delegate_data/2, delegate_data/3, delegate_data/4]).
-export([delegate_call/3, delegate_call/4, delegate_call/5]).
-export([delegate_cast/3, delegate_cast/4]).
-export([delegate_info/3, delegate_info/4]).

-export([add_handler/3]).
-export([remove_handler/3]).
-export([swap_handler/4]).

-export_type([context/0]).
-export_type([handler_result/0, handler_result/1]).
-export_type([position/0]).
-export_type([post_opt/0, post_opts/0]).

%%----------------------------------------------------------------------------------------------------------------------
%% Macros & Records & Types
%%----------------------------------------------------------------------------------------------------------------------
-define(CONTEXT, ?MODULE).

-record(?CONTEXT,
        {
          socket :: inet:socket(),
          codec :: gen_cop_codec:codec(),
          handlers = [] :: [gen_cop_handler:handler()], % XXX: non-empty check
          done_handlers = [] :: [gen_cop_handler:handler()],
          send_queue = [] :: [term()] % TODO: type
        }).

-opaque context() :: #?CONTEXT{}.

-type handler_result() :: handler_result(term()).
-type handler_result(Reason) :: {ok, context()} | {stop, Reason, context()}.

-type post_opts() :: [post_opt()].
-type post_opt() :: {remove, term()}
                  | {swap, term(), gen_cop_handler:spec()}.

-type position() :: front | back | pre | {pre, gen_cop_handler:id()} | post | {post, gen_cop_handler:id()}.

%%----------------------------------------------------------------------------------------------------------------------
%% Exported Functions
%%----------------------------------------------------------------------------------------------------------------------
-spec init(inet:socket(), gen_cop_codec:codec(), [gen_cop_handler:uninitialized_handler()]) ->
                  {ok, context()} | {stop, Reason} when
      Reason :: {already_present, gen_cop_handler:id()} | term().
init(Socket, Codec, Handlers) ->
    Context0 = #?CONTEXT{socket = Socket, codec = Codec},
    case handlers_init(lists:reverse(Handlers), Context0) of
        {stop, Reason, Context1} ->
            _ = handlers_terminate(Reason, Context1),
            {stop, Reason};
        {ok, Context1} ->
            {ok, Context1}
    end.

-spec send(gen_cop:data(), context()) -> context().
send(Data, Context) ->
    Context#?CONTEXT{send_queue = [Data | Context#?CONTEXT.send_queue]}.

-spec recv(binary(), context()) -> handler_result(). % XXX: name
recv(Bin, Context) ->
    case gen_cop_codec:decode(Bin, Context#?CONTEXT.codec) of
        {error, Reason, Codec} -> {stop, Reason, Context#?CONTEXT{codec = Codec}};
        {ok, Messages, Codec}  -> handle_messages(Messages, Context#?CONTEXT{codec = Codec})
    end.

-spec delegate_data(gen_cop:data(), context()) -> handler_result().
delegate_data(Data, Context) ->
    handle_data(Data, next_handler(Context)).

-spec delegate_data(gen_cop:data(), gen_cop_handler:state(), context()) -> handler_result().
delegate_data(Data, State, Context) ->
    handle_data(Data, next_handler(State, Context)).

-spec delegate_data(gen_cop:data(), gen_cop_handler:state(), context(), post_opts()) -> handler_result().
delegate_data(Data, State, Context0, Options) ->
    case handle_post_options(update_state(State, Context0), Options) of
        {stop, Reason, Context1} -> stop(Reason, Context1);
        {ok, Context1}           -> delegate_data(Data, Context1)
    end.

-spec delegate_call(term(), gen_cop:from(), context()) -> handler_result().
delegate_call(Request, From, Context) ->
    handle_call(Request, From, next_handler(Context)).

-spec delegate_call(term(), gen_cop:from(), gen_cop_handler:state(), context()) -> handler_result().
delegate_call(Request, From, State, Context) ->
    handle_call(Request, From, next_handler(State, Context)).

-spec delegate_call(term(), gen_cop:from(), gen_cop_handler:state(), context(), post_opts()) -> handler_result().
delegate_call(Request, From, State, Context0, Options) ->
    case handle_post_options(update_state(State, Context0), Options) of
        {stop, Reason, Context1} -> stop(Reason, Context1);
        {ok, Context1}           -> delegate_call(Request, From, Context1)
    end.

-spec delegate_cast(term(), context()) -> handler_result().
delegate_cast(Request, Context) ->
    handle_cast(Request, next_handler(Context)).

-spec delegate_cast(term(), gen_cop_handler:state(), context()) -> handler_result().
delegate_cast(Request, State, Context) ->
    handle_cast(Request, next_handler(State, Context)).

-spec delegate_cast(term(), gen_cop_handler:state(), context(), post_opts()) -> handler_result().
delegate_cast(Request, State, Context0, Options) ->
    case handle_post_options(update_state(State, Context0), Options) of
        {stop, Reason, Context1} -> stop(Reason, Context1);
        {ok, Context1}           -> delegate_cast(Request, Context1)
    end.

-spec delegate_info(term(), context()) -> handler_result().
delegate_info(Info, Context) ->
    handle_info(Info, next_handler(Context)).

-spec delegate_info(term(), gen_cop_handler:state(), context()) -> handler_result().
delegate_info(Info, State, Context) ->
    handle_info(Info, next_handler(State, Context)).

-spec delegate_info(term(), gen_cop_handler:state(), context(), post_opts()) -> handler_result().
delegate_info(Info, State, Context0, Options) ->
    case handle_post_options(update_state(State, Context0), Options) of
        {stop, Reason, Context1} -> stop(Reason, Context1);
        {ok, Context1}           -> delegate_info(Info, Context1)
    end.

-spec handle_call(term(), gen_cop:from(), context()) -> handler_result().
handle_call(Request, From, Context = #?CONTEXT{handlers = []}) ->
    stop({unhandled_call, Request, From}, Context);
handle_call(Request, From, Context = #?CONTEXT{handlers = [Handler | _]}) ->
    gen_cop_hander:handle_call(Request, From, Handler, Context).

-spec handle_cast(term(), context()) -> handler_result().
handle_cast(Request, Context = #?CONTEXT{handlers = []}) ->
    stop({unhandled_cast, Request}, Context);
handle_cast(Request, Context = #?CONTEXT{handlers = [Handler | _]}) ->
    gen_cop_handler:handle_cast(Request, Handler, Context).

-spec handle_info(term(), context()) -> handler_result().
handle_info(Info, Context = #?CONTEXT{handlers = []}) ->
    stop({unhandled_info, Info}, Context);
handle_info(Info, Context = #?CONTEXT{handlers = [Handler | _]}) ->
    gen_cop_handler:handle_info(Info, Handler, Context).

-spec flush_send_queue(context()) -> {ok, iodata(), context()} | {error, Reason::term(), context()}. % XXX: name
flush_send_queue(Context0 = #?CONTEXT{send_queue = Queue}) ->
    Result = gen_cop_codec:encode(lists:reverse(Queue), Context0#?CONTEXT.codec),
    Context1 = Context0#?CONTEXT{codec = element(3, Result), send_queue = []},
    setelement(3, Result, Context1).

-spec get_socket(context()) -> inet:socket().
get_socket(Context) ->
    gen_cop_session:get_socket(Context).

-spec terminate(term(), context()) -> context().
terminate(Reason, Context) ->
    handlers_terminate(Reason, Context).

%% XXX: tmp
-spec raise(Class, Reason, context()) -> {stop, Reason, context()} when
      Class :: throw | error | exit,
      Reason :: term().
raise(Class, Reason, Context) ->
    raise(Class, Reason, erlang:get_stacktrace(), Context).

-spec raise(Class, Reason, StackTrace, context()) -> {stop, Reason, context()} when
      Class :: throw | error | exit,
      Reason :: term(),
      StackTrace :: [term()]. % TODO:
raise(Class, Reason, StackTrace, Context) ->
    stop({'EXIT', {Class, Reason, StackTrace}}, Context).

-spec stop(Reason, context()) -> {stop, Reason, context()} when
      Reason :: term().
stop(Reason, Context) ->
    {stop, Reason, fix_handlers(Context)}.

-spec stop(Reason, gen_cop_handler:state(), context()) -> {stop, Reason, context()} when
      Reason :: term().
stop(Reason, State, Context) ->
    stop(Reason, update_state(State, Context)).

-spec ok(gen_cop_handler:state(), context(), post_opts()) -> handler_result().
ok(State, Context0, Options) ->
    case handle_post_options(update_state(State, Context0), Options) of
        {stop, Reason, Context1} -> stop(Reason, Context1);
        {ok, Context1}           -> ok(Context1)
    end.

-spec ok(gen_cop_handler:state(), context()) -> {ok, context()}.
ok(State, Context) ->
    ok(update_state(State, Context)).

-spec ok(context()) -> {ok, context()}.
ok(Context) ->
    {ok, fix_handlers(Context)}.

-spec handle_post_options(context(), post_opts()) -> handler_result().
handle_post_options(Context, []) ->
    {ok, Context};
handle_post_options(Context0, [{remove, RemoveReason} | Options]) ->
    case remove_handler(gen_cop_handler:get_id(hd(Context0#?CONTEXT.handlers)), RemoveReason, Context0) of
        {error, Reason, Context1} -> {stop, Reason, Context1};
        {ok, Context1}            -> handle_post_options(Context1, Options)
    end;
handle_post_options(Context0, [{swap, SwapReason, Spec} | Options]) ->
    case swap_handler(gen_cop_handler:get_id(hd(Context0#?CONTEXT.handlers)), SwapReason, Spec, Context0) of
        {error, Reason, Context1} -> {stop, Reason, Context1};
        {ok, Context1}            -> handle_post_options(Context1, Options)
    end.

-spec add_handler(position(), gen_cop_handler:spec(), context()) -> {ok, context()} | {error, Reason, context()} when
      Reason :: not_found | {already_present, gen_cop_handler:id()} | term().
add_handler(Position, Spec, Context0) ->
    Handler0 = gen_cop_handler:make_instance(Spec),
    case handlers_split(gen_cop_handler:get_id(Handler0), Context0#?CONTEXT.handlers ++ Context0#?CONTEXT.done_handlers, []) of  % TODO: refactoring
        {ok, _, _, _} -> {error, {already_present, gen_cop_handler:get_id(Handler0)}, Context0};
        error         ->
            case gen_cop_handler:init(Handler0, Context0) of
                {stop, Reason, Context1} -> {error, Reason, Context1};
                {ok, Context1}           ->
                    #?CONTEXT{handlers = [Handler1, Current | Handlers], done_handlers = Dones} = Context1,
                    Context2 = Context1#?CONTEXT{handlers = [Current | Handlers]},
                    case Position of
                        front     -> Context2#?CONTEXT{done_handlers = Dones ++ [Handler1]};
                        back      -> Context2#?CONTEXT{handlers = [Current | Handlers] ++ [Handler1]};
                        pre       -> Context2#?CONTEXT{done_handlers = [Handler1 | Dones]};
                        post      -> Context2#?CONTEXT{handlers = [Current, Handler1 | Handlers]};
                        {Pos, Id} ->
                            FullHandlers = lists:reverse(Dones, [Current | Handlers]),
                            case handlers_split(Id, FullHandlers, []) of
                                error                  -> {error, not_found, Context2};
                                {ok, Pres, Mid, Posts} ->
                                    FullHandlers1 = % XXX: variable name
                                        case Pos of
                                            pre  -> Pres ++ [Handler1, Mid] ++ Posts;
                                            post -> Pres ++ [Mid, Handler1] ++ Posts
                                        end,
                                    {ok, Pres1, _, Posts1} = handlers_split(gen_cop_handler:get_id(Current), FullHandlers1, []),
                                    {ok, Context2#?CONTEXT{handlers = [Current | Posts1], done_handlers = lists:reverse(Pres1)}}
                            end
                    end
            end
    end.

-spec remove_handler(gen_cop_handler:id(), RemoveReason, context()) -> {ok, context()} | {error, ErrorReason, context()} when
      RemoveReason :: term(),
      ErrorReason  :: not_found | in_active | term().
remove_handler(Id, RemoveReason, Context0) ->
    #?CONTEXT{handlers = [Current | Handlers], done_handlers = Dones} = Context0,
    case Id =:= gen_cop_handler:get_id(Current) of
        true  -> {error, in_active, Context0};
        false ->
            case handlers_split(Id, lists:reverse(Dones, [Current | Handlers]), []) of
                error                  -> {error, not_found, Context0};
                {ok, Pres, Mid, Posts} ->
                    case gen_cop_handler:terminate(RemoveReason, Mid, Context0) of
                        {stop, Reason, Context1} -> {error, Reason, Context1};
                        {ok, Context1}           ->
                            %% TODO:
                            {ok, Pres1, _, Posts1} = handlers_split(gen_cop_handler:get_id(Current), Pres ++ Posts, []),
                            {ok, Context1#?CONTEXT{handlers = [Current | Posts1], done_handlers = lists:reverse(Pres1)}}
                    end
            end
    end.

-spec swap_handler(gen_cop_handler:id(), SwapReason, gen_cop_handler:spec(), context()) -> {ok, context()} | {error, ErrorReason, context()} when
      SwapReason  :: term(),
      ErrorReason :: not_found | in_active | {already_present, gen_cop_handler:id()} | term().
swap_handler(RemoveId, SwapReason, Spec, Context0) ->
    Position  = get_nearest_position(RemoveId, Context0),
    case remove_handler(RemoveId, SwapReason, Context0) of
        {error, Reason, Context1} -> {error, Reason, Context1};
        {ok, Context1}            -> add_handler(Position, Spec, Context1)
    end.

-spec get_nearest_position(gen_cop_handler:id(), context()) -> position().
get_nearest_position(Id, Context) -> % TODO: rename
    case handlers_split(Id, lists:reverse(Context#?CONTEXT.done_handlers, Context#?CONTEXT.handlers), []) of % TODO: refactoring
        error                  -> front; % XXX:
        {ok, [], _, []}        -> front; % XXX:
        {ok, _, _, [Next | _]} -> {pre, gen_cop_handler:get_id(Next)};
        {ok, List, _, _}       -> {post, gen_cop_handler:get_id(lists:last(List))}
    end.

-spec handlers_split(gen_cop_handler:id(), [gen_cop_handler:handler()], [gen_cop_handler:handler()]) ->
                            {ok, [gen_cop_handler:handler()], gen_cop_handler:handler(), [gen_cop_handler:handler()]} | error.
handlers_split(_Id, [], _Acc) ->
    error;
handlers_split(Id, [H | Hs], Acc) ->
    case Id =:= gen_cop_handler:get_id(H) of
        true  -> {ok, lists:reverse(Acc), H, Hs};
        false -> handlers_split(Id, Hs, [H | Acc])
    end.

%%----------------------------------------------------------------------------------------------------------------------
%% Internal Functions
%%----------------------------------------------------------------------------------------------------------------------
-spec handlers_init([gen_cop_hander:uninitialized_handler()], context()) -> handler_result().
handlers_init([], Context) ->
    {ok, Context};
handlers_init([Handler | Rest], Context0) ->
    case handlers_split(gen_cop_handler:get_id(Handler), Context0#?CONTEXT.handlers, []) of % TODO: refactoring
        {ok, _, _, _} -> {stop, {already_present, gen_cop_handler:get_id(Handler)}, Context0};
        error         ->
            case gen_cop_handler:init(Handler, Context0#?CONTEXT{handlers = [Handler | Context0#?CONTEXT.handlers]}) of
                {stop, Reason, Context1} -> {stop, Reason, Context1};
                {ok, Context1}           -> handlers_init(Rest, Context1)
            end
    end.

-spec handlers_terminate(term(), context()) -> context().
handlers_terminate(_Reason, Context = #?CONTEXT{handlers = []}) ->
    Context;
handlers_terminate(Reason, Context0 = #?CONTEXT{handlers = [Handler | RestHandlers]}) ->
    ok = case gen_cop_handler:terminate(Reason, Handler, Context0) of
             {stop, _, Context1} -> ok; % XXX: note
             {ok, Context1}      -> ok
         end,
    Context2 = Context1#?CONTEXT{handlers = RestHandlers},
    handlers_terminate(Reason, Context2).

-spec handle_messages([gen_cop:data()], context()) -> handler_result().
handle_messages([], Context) ->
    {ok, Context};
handle_messages([Msg | Messages], Context0) ->
    case handle_data(Msg, Context0) of
        {stop, Reason, Context1} -> {stop, Reason, Context1};
        {ok, Context1}            -> handle_messages(Messages, Context1)
    end.

-spec handle_data(gen_cop:data(), context()) -> handler_result().
handle_data(Data, Context = #?CONTEXT{handlers = []}) ->
    stop({unhandled_data, Data}, Context);
handle_data(Data, Context = #?CONTEXT{handlers = [Handler | _]}) ->
    gen_cop_handler:handle_data(Data, Handler, Context).

-spec update_state(gen_cop_handler:state(), context()) -> context().
update_state(State, Context = #?CONTEXT{handlers = [{Header, _} | Handlers]}) ->
    Context#?CONTEXT{handlers = [{Header, State} | Handlers]}.

-spec next_handler(gen_cop_handler:state(), context()) -> context().
next_handler(State, Context = #?CONTEXT{handlers = [{Header, _} | Handlers], done_handlers = Dones}) ->
    Context#?CONTEXT{handlers = Handlers, done_handlers = [{Header, State} | Dones]}.

-spec next_handler(context()) -> context().
next_handler(Context = #?CONTEXT{handlers = [Handler | Handlers], done_handlers = Dones}) ->
    Context#?CONTEXT{handlers = Handlers, done_handlers = [Handler | Dones]}.

-spec fix_handlers(context()) -> context().
fix_handlers(Context = #?CONTEXT{done_handlers = Dones, handlers = Tail}) ->
    Context#?CONTEXT{handlers = lists:reverse(Dones, Tail), done_handlers = []}.
