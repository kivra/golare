-module(golare_logger_h).

-behavior(logger_handler).

-export([add/0]).
-export([remove/0]).
-export([adding_handler/1]).
-export([removing_handler/1]).
-export([changing_config/3]).
-export([filter_config/1]).
-export([log/2]).

%%% Handler management API

add() ->
    case logger:get_handler_config(golare) of
        {ok, _Config} ->
            ok;
        {error, {not_found, _}} ->
            Level = golare_config:logger_level(),
            Config = #{
                config => #{},
                level => Level,
                filter_default => log,
                filters => [{golare, {fun logger_filters:domain/2, {stop, sub, [golare]}}}]
            },
            ok = logger:add_handler(golare, ?MODULE, Config)
    end.

remove() ->
    ok = logger:remove_handler(golare).

%%% logger_handler callbacks

-spec adding_handler(Config1) -> {ok, Config2} | {error, Reason} when
    Config1 :: logger_handler:config(), Config2 :: logger_handler:config(), Reason :: term().
adding_handler(Config) ->
    {ok, Config}.

-spec removing_handler(Config) -> ok when Config :: logger_handler:config().
removing_handler(_Config) ->
    ok.

-spec changing_config(SetOrUpdate, OldConfig, NewConfig) -> {ok, Config} | {error, Reason} when
    SetOrUpdate :: set | update,
    OldConfig :: logger_handler:config(),
    NewConfig :: logger_handler:config(),
    Config :: logger_handler:config(),
    Reason :: term().
changing_config(_SetOrUpdate, _OldConfig, NewConfig) ->
    {ok, NewConfig}.

-spec filter_config(Config) -> FilteredConfig when
    Config :: logger_handler:config(), FilteredConfig :: logger_handler:config().
filter_config(Config) ->
    Config.

-spec log(logger:log_event(), logger_handler:config()) -> term().
log(LogEvent, _Config) ->
    try
        Event0 = #{
            level => sentry_level(LogEvent),
            timestamp => event_timestamp(LogEvent)
        },
        Event1 = logger_name(Event0, LogEvent),
        Event2 = describe(Event1, LogEvent),
        Event = maybe_exception(Event2, LogEvent),
        {ok, _EventId} = golare:capture_event(Event)
    catch
        Type:Rsn:Trace ->
            ExceptionValue0 =
                #{
                    type => <<"golare sdk crash">>,
                    value => format("~s:~tp", [Type, Rsn])
                },
            case [frame(T) || T <- Trace] of
                [] ->
                    ExceptionValue = ExceptionValue0;
                Frames ->
                    ExceptionValue = ExceptionValue0#{
                        stacktrace => #{frames => lists:reverse(Frames)}
                    }
            end,
            Crash = #{
                exception => #{
                    values => [ExceptionValue]
                }
            },
            % OTP logger removes a handler whose log/2 raises, which would end
            % all Sentry reporting until the transport restarts and adds the
            % handler again. Keep that structurally impossible rather than
            % relying on every callee staying exit-free: capturing the crash
            % report is best effort, and reporting a failure here would mean
            % logging from inside the log handler.
            try
                golare:capture_event(Crash)
            catch
                _:_ ->
                    ok
            end
    end.

%% Internal

sentry_level(#{level := Level}) ->
    sentry_level(Level);
sentry_level(emergency) ->
    fatal;
sentry_level(alert) ->
    fatal;
sentry_level(critical) ->
    fatal;
sentry_level(error) ->
    error;
sentry_level(warning) ->
    warning;
sentry_level(notice) ->
    info;
sentry_level(info) ->
    info;
sentry_level(debug) ->
    debug;
sentry_level(_) ->
    info.

event_timestamp(#{meta := #{time := MicrosecondEpoch}}) ->
    Opts = [{unit, microsecond}, {offset, "Z"}],
    Rfc3339 = calendar:system_time_to_rfc3339(MicrosecondEpoch, Opts),
    iolist_to_binary(Rfc3339).

logger_name(Event, #{msg := {report, #{label := Label}}}) ->
    Event#{logger => format("~p", [Label])};
logger_name(Event, #{meta := #{mfa := {M, F, A}}}) ->
    Event#{logger => format("~s:~s/~b", [M, F, A])};
logger_name(Event, _) ->
    Event.

describe(Event0, #{msg := {report, TopReport}, meta := #{report_cb := ReportFun}}) when
    is_map(TopReport)
->
    case ReportFun of
        Fun when is_function(Fun, 1) ->
            {FormatString, Params} = Fun(TopReport),
            LogEntry = #{
                formatted => format(FormatString, Params),
                message => unicode:characters_to_binary(FormatString),
                params => [format("~tp", [P]) || P <- Params]
            };
        Fun when is_function(Fun, 2) ->
            Config = #{
                depth => unlimited,
                chars_limit => unlimited,
                single_line => false
            },
            Formatted = Fun(TopReport, Config),
            LogEntry = #{
                formatted => unicode:characters_to_binary(Formatted)
            }
    end,
    Event1 = Event0#{
        logentry => LogEntry
    },
    case TopReport of
        #{label := {proc_lib, crash} = _Label, report := [Info, LinkedInfos]} ->
            CrashThread0 = #{
                id => print(self()),
                name => print_list([
                    proplists:get_value(registered_name, Info), lists:keyfind(initial_call, 1, Info)
                ])
            },
            case lists:keyfind(error_info, 1, Info) of
                false ->
                    CrashThread = CrashThread0;
                {error_info, {_ErrorClass, _Reason, Trace}} ->
                    CrashThread = CrashThread0#{
                        crashed => true,
                        current => true,
                        stacktrace => #{
                            frames => lists:reverse([frame(T) || T <- Trace])
                        }
                    }
            end,
            LinkedThreads = [
                #{
                    id => print(proplists:get_value(pid, LI)),
                    name => print(proplists:get_value(registered_name, LI)),
                    current => false,
                    stacktrace => #{
                        frames => lists:reverse([
                            frame(T)
                         || T <- proplists:get_value(current_stacktrace, LI, [])
                        ])
                    }
                }
             || {neighbour, LI} <- LinkedInfos
            ],
            Event1#{
                threads => #{
                    values => [CrashThread] ++ LinkedThreads
                }
            };
        #{label := {supervisor, _} = Label, report := Info} ->
            Event1#{
                exception => #{
                    values => [
                        #{
                            type => print_list([Label, lists:keyfind(supervisor, 1, Info)]),
                            value => print(lists:keyfind(reason, 1, Info))
                        }
                    ]
                }
            };
        #{
            label := {gen_server, _} = Label,
            name := Name,
            reason := Reason0,
            client_info := ClientInfo
        } ->
            ServerThread0 = #{
                id => print(self()),
                name => format("server ~tp", [Name]),
                state => print(Label),
                current => true,
                crashed => true
            },
            case ClientInfo of
                undefined ->
                    ClientThreads = [];
                {ClientPid, {ClientName, ClientTrace}} ->
                    ClientThreads = [
                        #{
                            id => print(ClientPid),
                            name => format("client ~tp", [ClientName]),
                            crashed => true,
                            stacktrace => #{
                                frames => lists:reverse([frame(F) || F <- ClientTrace])
                            }
                        }
                    ]
            end,
            case Reason0 of
                {_Reason, [{_Mod, _Fun, _A, _Opts} | _] = ServerTrace} when
                    is_atom(_Mod), is_atom(_Fun), is_list(_Opts)
                ->
                    ServerThread =
                        ServerThread0#{
                            stacktrace => #{
                                frames => lists:reverse([frame(F) || F <- ServerTrace])
                            }
                        };
                _ ->
                    ServerThread = ServerThread0
            end,
            Event1#{
                threads => #{
                    values => [ServerThread | ClientThreads]
                }
            };
        _ ->
            Event1
    end;
describe(E0, #{msg := {report, Report}, meta := Meta}) when is_map(Report) ->
    Fields = [message, msg, reason],
    case maps:with(Fields, Report) of
        Map when map_size(Map) > 0 ->
            Values = [{F, maps:get(F, Map)} || F <- Fields, is_map_key(F, Map)],
            {_, Message} = hd(Values);
        _ ->
            Message = Report
    end,
    E1 = E0#{
        logentry =>
            #{formatted => format("~tkp", [Message])}
    },
    describe_log(E1, Message, Report, Meta);
describe(E0, #{msg := {report, Report}, meta := Meta}) when is_list(Report) ->
    Fields = [message, msg, reason],
    case [lists:keyfind(F, 1, Report) || F <- Fields, lists:keymember(F, 1, Report)] of
        [] ->
            Message = Report;
        Values ->
            {_, Message} = hd(Values)
    end,
    E1 = E0#{
        logentry =>
            #{formatted => format("~tkp", [Message])}
    },
    describe_log(E1, Message, Report, Meta);
describe(E0, #{msg := {string, Raw}, meta := Meta}) ->
    E1 = E0#{
        logentry =>
            #{formatted => unicode:characters_to_binary(Raw)}
    },
    maybe_mfa(E1, Raw, Meta);
describe(E0, #{msg := {FormatString, Params}, meta := Meta}) when is_list(Params) ->
    E1 = E0#{
        logentry =>
            #{
                formatted => format(FormatString, Params),
                message => unicode:characters_to_binary(FormatString),
                params => [format("~tp", [P]) || P <- Params]
            }
    },
    maybe_mfa(E1, FormatString, Meta);
describe(Event0, #{msg := Fallback}) ->
    Event0#{
        logentry =>
            #{formatted => print(Fallback)}
    }.

describe_log(E0, Message, Report, Meta) when is_list(Report) ->
    E1 = maybe_mfa(E0, Message, Meta),
    E1#{
        extra => maps:from_list([{K, print(V)} || {K, V} <- Report, is_atom(K)])
    };
describe_log(E0, Message, Report, Meta) when is_map(Report) ->
    E1 = maybe_mfa(E0, Message, Meta),
    E1#{
        extra => #{K => print(V) || K := V <- Report, is_atom(K)}
    }.

%% Attach an exception interface when the log event carries a raw Erlang
%% stacktrace, either in the logger metadata or in the report itself. The
%% stacktrace makes Sentry group the event by frames instead of by message.
%% Crash reports handled by describe/2 build their own exception or threads
%% and are left untouched.
maybe_exception(#{exception := _} = Event, _LogEvent) ->
    Event;
maybe_exception(#{threads := _} = Event, _LogEvent) ->
    Event;
maybe_exception(Event, #{msg := Msg} = LogEvent) ->
    Meta = maps:get(meta, LogEvent, #{}),
    Report = msg_report(Msg),
    case stacktrace_of(Meta, Report) of
        undefined ->
            Event;
        {Source, Trace} ->
            Event1 = Event#{
                exception => #{
                    values => [
                        #{
                            type => exception_type(Report, Meta, Event),
                            value => exception_value(Report, Event),
                            mechanism => #{type => logging, handled => true},
                            stacktrace => #{
                                frames => lists:reverse([frame(T) || T <- Trace])
                            }
                        }
                    ]
                }
            },
            drop_duplicate_extra(Source, Event1)
    end.

%% A report-sourced stacktrace is already in extra, printed by describe_log/4,
%% and would now be sent a second time as frames. Sentry renders the frames,
%% so keep those and drop the printed copy. A meta-sourced stacktrace leaves
%% extra alone: the report may hold a different or malformed stacktrace value
%% that the frames above do not represent.
drop_duplicate_extra(report, #{extra := Extra} = Event) ->
    case maps:remove(stacktrace, Extra) of
        Remaining when map_size(Remaining) =:= 0 -> maps:remove(extra, Event);
        Remaining -> Event#{extra => Remaining}
    end;
drop_duplicate_extra(_Source, Event) ->
    Event.

msg_report({report, Report}) when is_map(Report) ->
    Report;
msg_report({report, Report}) when is_list(Report) ->
    maps:from_list([{K, V} || {K, V} <- Report, is_atom(K)]);
msg_report(_Msg) ->
    #{}.

stacktrace_of(Meta, Report) ->
    Candidates = [
        {meta, maps:get(stacktrace, Meta, undefined)},
        {report, maps:get(stacktrace, Report, undefined)}
    ],
    case [{Source, T} || {Source, T} <- Candidates, is_stacktrace(T)] of
        [Found | _] -> Found;
        [] -> undefined
    end.

is_stacktrace([_ | _] = Trace) -> lists:all(fun is_stackframe/1, Trace);
is_stacktrace(_) -> false.

is_stackframe({M, F, A, Opts}) when is_atom(M), is_atom(F), is_list(Opts) ->
    is_integer(A) orelse is_list(A);
is_stackframe(_) ->
    false.

exception_type(#{exception := Exception}, _Meta, _Event) ->
    print(Exception);
exception_type(Report, Meta, Event) ->
    case exception_class(Meta, Report) of
        undefined -> exception_value(Report, Event);
        Class -> print(Class)
    end.

exception_class(#{class := Class}, _Report) when is_atom(Class) ->
    Class;
exception_class(_Meta, #{class := Class}) when is_atom(Class) ->
    Class;
exception_class(_Meta, #{exception_class := Class}) when is_atom(Class) ->
    Class;
exception_class(_Meta, _Report) ->
    undefined.

exception_value(Report, _Event) when map_size(Report) > 0 ->
    Fields = [message, msg, reason],
    case [maps:get(F, Report) || F <- Fields, is_map_key(F, Report)] of
        [Message | _] -> format("~tkp", [Message]);
        [] -> format("~tkp", [Report])
    end;
exception_value(_Report, #{logentry := #{formatted := Formatted}}) ->
    Formatted;
exception_value(_Report, _Event) ->
    <<"unknown">>.

maybe_mfa(E0, _Message, _Meta) ->
    E0.

frame({M, F, A, Opts}) ->
    case A of
        _ when is_integer(A) -> ArgNum = A;
        _ when is_list(A) -> ArgNum = length(A)
    end,
    F0 = #{
        function => format("~tp:~tp/~b", [M, F, ArgNum]),
        in_app => frame_in_app(lists:keyfind(file, 1, Opts))
    },
    F1 = frame_extra(F0, lists:keyfind(file, 1, Opts)),
    F2 = frame_extra(F1, lists:keyfind(line, 1, Opts)),
    F2.

frame_in_app({file, "/" ++ _ = File}) ->
    % Rebar3 keeps dependency source trees under `_build`, so absolute paths
    % that do not contain `_build` are treated as application code. Relative
    % paths (OTP modules) and frames without file info are not.
    case string:find(File, "/_build/") of
        nomatch -> true;
        _Match -> false
    end;
frame_in_app(_File) ->
    false.

frame_extra(F, {file, String}) ->
    F#{filename => unicode:characters_to_binary(String)};
frame_extra(F, {line, Line}) ->
    F#{lineno => Line};
frame_extra(F, _) ->
    F.

format(Format, Args) ->
    try
        Msg = io_lib:format(Format, Args),
        unicode:characters_to_binary(Msg)
    catch
        error:badarg ->
            print([format_error, Format, Args])
    end.

print(Term) -> print_list([Term]).
print_list(Terms) ->
    Printed = [io_lib:print(T) || T <- Terms],
    unicode:characters_to_binary(lists:join(" ", Printed)).
