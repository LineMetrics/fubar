%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : Fubar log manager.
%%%
%%% Created : Nov 30, 2012
%%% -------------------------------------------------------------------
-module(fubar_log).
-author("Sungjin Park <jinni.park@gmail.com>").
-behavior(gen_server).

%%
%% Includes
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("fubar.hrl").
-include("sasl_log.hrl").
-include("props_to_record.hrl").

%%
%% Macros, records and types
%%
-record(?MODULE, {dir = "priv/log" :: string(),
				  max_bytes = 10485760 :: integer(),
				  max_files = 10 :: integer(),
				  classes = [] :: [{atom(), term(), null | standard_io | pid()}],
				  interval = 500 :: timeout()}).

%%
%% Exports
%%
-export([start_link/0, log/3, trace/2, dump/2,
		 open/1, close/1, show/1, hide/1, interval/1, state/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% @doc Start a log manager.
%%      The log manager process manages disk_logs and polls them.
-spec start_link() -> {ok, pid()} | {error, reason()}.
start_link() ->
	State = ?PROPS_TO_RECORD(fubar:settings(?MODULE), ?MODULE),
	Path = filename:join(State#?MODULE.dir, io_lib:format("~s", [node()])),
	ok = filelib:ensure_dir(Path++"/"),
	gen_server:start({local, ?MODULE}, ?MODULE, State#?MODULE{dir=Path}, []).

%% @doc Leave a log.
%%      The log is dropped unless the class is open in advance.
%% @sample fubar_log:log(debug, my_module, Term).
-spec log(atom(), term(), term()) -> ok | {error, reason()}.
log(Class, Tag, Term) ->
	Now = now(),
	Calendar = calendar:now_to_universal_time(Now),
	Timestamp = httpd_util:rfc1123_date(Calendar),
	catch disk_log:log(Class, {{Class, Timestamp}, {Tag, self()}, Term}).

%% @doc Leave a special trace type log.
%% @sample fubar_log:trace(my_module, Fubar).
-spec trace(term(), #fubar{}) -> ok.
trace(_, #fubar{id=undefined}) ->
	ok;
trace(Tag, #fubar{id=Id, origin={Origin, T1}, from={From, T2}, via={Via, T3}, payload=Payload}) ->
	Now = now(),
	Calendar = calendar:now_to_universal_time(Now),
	Timestamp = httpd_util:rfc1123_date(Calendar),
	catch disk_log:log(trace, {{'TRACE', Timestamp}, {Tag, self()},
							   {fubar, Id},
							   {since, {Origin, timer:now_diff(Now, T1)/1000},
									   {From, timer:now_diff(Now, T2)/1000},
									   {Via, timer:now_diff(Now, T3)/1000}},
							   {payload, Payload}}).

%% @doc Dump a log class as a text file.
-spec dump(atom(), string()) -> ok.
dump(Class, Path) ->
	case state() of
		#?MODULE{dir=Dir} ->
			case file:open(Path, [write]) of
				{ok, File} ->
					LogFile = filename:join(Dir, io_lib:format("~s", [Class])),
					disk_log:open([{name, Class}, {file, LogFile}]),
					consume_log(Class, start, File),
					disk_log:close(Class),
					file:close(File);
				Error1 ->
					Error1
			end;
		Error ->
			Error
	end.

%% @doc Open a log class.
%%      Opening a log class doesn't mean the logs in the class is shown in tty.
%%      Need to call show/1 explicitly to do that.
-spec open(atom()) -> ok.
open(Class) ->
	gen_server:call(?MODULE, {open, Class}).

%% @doc Close a log class.
%%      Closing a log class mean that the logs in the class is no longer stored.
-spec close(atom()) -> ok.
close(Class) ->
	gen_server:call(?MODULE, {close, Class}).

%% @doc Print logs in a class to tty.
-spec show(atom()) -> ok.
show(Class) ->
	gen_server:call(?MODULE, {show, Class}).

%% @doc Hide logs in a class from tty.
-spec hide(atom()) -> ok.
hide(Class) ->
	gen_server:call(?MODULE, {hide, Class}).

%% @doc Set tty refresh interval.
-spec interval(timeout()) -> ok.
interval(T) ->
	gen_server:call(?MODULE, {interval, T}).

%% @doc Get the log manager state.
-spec state() -> #?MODULE{}.
state() ->
	gen_server:call(?MODULE, state).

%%
%% Callback Functions
%%
init(State=#?MODULE{dir=Dir, max_bytes=L, max_files=N, classes=Classes, interval=T}) ->
	?DEBUG([init, State]),
	Init = fun(Class) -> open(Class, Dir, L, N) end,
	{ok, State#?MODULE{classes=lists:map(Init, Classes)}, T}.

handle_call({open, Class}, _, State=#?MODULE{dir=Dir, max_bytes=L, max_files=N, interval=T}) ->
	open(Class, Dir, L, N),
	{reply, ok, State, T};
handle_call({close, Class}, _, State=#?MODULE{classes=Classes, interval=T}) ->
	Result = disk_log:close(Class),
	NewClasses = case lists:keytake(Class, 1, Classes) of
					 {value, {Class, _, _}, Rest} -> Rest;
					 false -> Classes
				 end,
	{reply, Result, State#?MODULE{classes=NewClasses}, T};
handle_call({show, Class}, _, State=#?MODULE{classes=Classes, interval=T}) ->
	case lists:keytake(Class, 1, Classes) of
		{value, {Class, Last, _}, Rest} ->
			Current = consume_log(Class, Last, null),
			{reply, ok, State#?MODULE{classes=[{Class, Current, standard_io} | Rest]}, T};
		false ->
			Current = consume_log(Class, start, null),
			{reply, ok, State#?MODULE{classes=[{Class, Current, standard_io} | Classes]}, T}
	end;
handle_call({hide, Class}, _, State=#?MODULE{classes=Classes, interval=T}) ->
	case lists:keytake(Class, 1, Classes) of
		{value, {Class, Current, _}, Rest} ->
			{reply, ok, State#?MODULE{classes=[{Class, Current, null} | Rest]}, T};
		false ->
			{reply, ok, State, T}
	end;
handle_call({interval, T}, _, State=#?MODULE{interval=_}) ->
	{reply, ok, State#?MODULE{interval=T}, T};
handle_call(state, _, State=#?MODULE{interval=T}) ->
	{reply, State, State, T};
handle_call(Request, From, State) ->
	?WARNING([handle_call, Request, From, State, "dropping unknown"]),
	{reply, ok, State}.

handle_cast(Message, State) ->
	?WARNING([handle_cast, Message, State, "dropping unknown"]),
	{noreply, State}.

handle_info(timeout, State) ->
	F = fun({Class, Last, Show}) ->
			Current = consume_log(Class, Last, Show),
			{Class, Current, Show}
		end,
	Classes = lists:map(F, State#?MODULE.classes),
	{noreply, State#?MODULE{classes=Classes}, State#?MODULE.interval};
handle_info(Info, State) ->
	?WARNING([handle_info, Info, State, "dropping unknown"]),
	{noreply, State}.

terminate(Reason, State) ->
	?DEBUG([terminate, Reason, State]),
	Close = fun({Class, _, _}) ->
				disk_log:close(Class)
			end,
	lists:foreach(Close, State#?MODULE.classes),
	Reason.

code_change(OldVsn, State, Extra) ->
	?WARNING([code_change, OldVsn, State, Extra]),
	{ok, State}.

%%
%% Local Functions
%%
open(Class, Dir, L, N) ->
   File = filename:join(Dir, io_lib:format("~s", [Class])),
   disk_log:open([{name, Class}, {file, File}, {type, wrap}, {size, {L, N}}]),
   Current = consume_log(Class, start, null),
   {Class, Current, standard_io}.

consume_log(Log, Last, Io) ->
	case disk_log:chunk(Log, Last) of
		{error, _} ->
			Last;
		eof ->
			Last;
		{Current, Terms} ->
			case Io of
				null ->
					start;
				_ ->
					Print = fun(Term) -> io:format(Io, "~p~n", [Term]) end,
					lists:foreach(Print, Terms)
			end,
			consume_log(Log, Current, Io)
	end.

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.