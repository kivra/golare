-module(golare_sentry_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

%% Includes
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("kernel/include/logger.hrl").

suite() ->
    [{timetrap, {seconds, 30}}].

init_per_suite(Config) ->
    ct_helper:make_certs_in_ets(),
    application:set_env(
        golare,
        tls_opts,
        ct_helper:get_certs_from_ets()
    ),
    {ok, Apps} = application:ensure_all_started([golare, cowboy]),
    {ok, _Pid} = sentry_mock_server:start(),
    ok = wait_connected(20),
    [{apps, Apps} | Config].

wait_connected(N) when N > 0 ->
    case sys:get_state(golare_transport) of
        {available, _} ->
            ok;
        {connecting, _} ->
            timer:sleep(500),
            wait_connected(N - 1)
    end;
wait_connected(0) ->
    exit(not_connecting).

end_per_suite(Config) ->
    sentry_mock_server:stop(),
    [application:stop(App) || App <- ?config(apps, Config)],
    ok.

init_per_group(_, Config) ->
    Config.

end_per_group(_, _Config) ->
    ok.

init_per_testcase(_TestName, Config) ->
    ok = sentry_mock_server:hear(self()),
    Config.

end_per_testcase(_TestName, _Config) ->
    ok.

%%%% Internal

%%%% Tests

groups() ->
    [
        {scope, [shuffle], [
            user_scope,
            transaction_scope
        ]},
        {log, [shuffle], [
            string_log,
            string_log_mfa,
            format_log,
            format_log_mfa,
            report_map,
            report_map_stacktrace_meta,
            report_map_stacktrace_in_report,
            format_log_stacktrace_meta,
            supervisor_crash,
            proc_lib_crash
        ]}
    ].

all() ->
    [
        basic,
        {group, scope},
        {group, log}
    ].

basic(_Config) ->
    {ok, EventId} = golare:capture_event(#{message => basic}),
    ?assertMatch(<<_Data:16/binary>>, EventId),
    {Header, Item} = wait_for(EventId),
    ct:pal(info, "This is the header:~n~p~nand this is the item:~n~p", [Header, Item]),
    ?assertMatch(
        #{
            <<"contexts">> := #{
                <<"os">> := #{
                    <<"name">> := _,
                    <<"version">> := _
                },
                <<"runtime">> := #{
                    <<"name">> := _,
                    <<"version">> := _
                }
            },
            <<"modules">> := _,
            <<"sdk">> := #{
                <<"name">> := _,
                <<"version">> := _
            },
            <<"server_name">> := _,
            <<"user">> := _,
            <<"environment">> := _,
            <<"message">> := <<"basic">>
        },
        Item
    ),
    ok.

user_scope(_Config) ->
    erlang:put({golare, user}, <<"testuser">>),
    {ok, EventId} = golare:capture_event(#{message => basic}),
    {_Header, Item} = wait_for(EventId),
    ?assertMatch(#{<<"user">> := <<"testuser">>}, Item),
    erlang:erase({golare, user}),
    ok.

transaction_scope(_Config) ->
    erlang:put({golare, transaction}, <<"testtransaction">>),
    {ok, EventId} = golare:capture_event(#{message => basic}),
    {_Header, Item} = wait_for(EventId),
    ?assertMatch(#{<<"transaction">> := <<"testtransaction">>}, Item),
    erlang:erase({golare, transaction}),
    ok.

string_log(_Config) ->
    LogItem = #{level => warning, meta => #{time => 0}, msg => {string, <<"hello world">>}},
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    ct:pal(default, "Captured: ~p", [Item]),
    ?assertMatch(
        #{
            <<"level">> := <<"warning">>,
            <<"timestamp">> := <<"1970-01-01T00:00:00", _/binary>>,
            <<"logentry">> := #{<<"formatted">> := <<"hello world">>}
        },
        Item
    ),
    ok.

string_log_mfa(_Config) ->
    LogItem = #{
        level => warning,
        meta => #{time => 0, mfa => {foo, bar, 0}, file => "foo.erl", line => 42},
        msg => {string, <<"hello world">>}
    },
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    ct:pal(default, "Captured: ~p", [Item]),
    ?assertMatch(
        #{
            <<"level">> := <<"warning">>,
            <<"logger">> := <<"foo:bar/0">>,
            <<"timestamp">> := <<"1970-01-01T00:00:00", _/binary>>,
            <<"logentry">> := #{<<"formatted">> := <<"hello world">>}
        },
        Item
    ),
    ok.

format_log(_Config) ->
    LogItem = #{level => warning, meta => #{time => 0}, msg => {"format ~b", [42]}},
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    ct:pal(default, "Captured: ~p", [Item]),
    ?assertMatch(
        #{
            <<"level">> := <<"warning">>,
            <<"timestamp">> := <<"1970-01-01T00:00:00", _/binary>>,
            <<"logentry">> := #{
                <<"message">> := <<"format ~b">>,
                <<"formatted">> := <<"format 42">>,
                <<"params">> := [_]
            }
        },
        Item
    ),
    ok.

format_log_mfa(_Config) ->
    Meta = #{time => 0, mfa => {foo, bar, 0}, file => "foo.erl", line => 42},
    LogItem = #{level => warning, meta => Meta, msg => {"format ~b", [42]}},
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    ct:pal(default, "Captured: ~p", [Item]),
    ?assertMatch(
        #{
            <<"level">> := <<"warning">>,
            <<"timestamp">> := <<"1970-01-01T00:00:00", _/binary>>,
            <<"logentry">> := #{
                <<"message">> := <<"format ~b">>,
                <<"formatted">> := <<"format 42">>,
                <<"params">> := [_]
            }
        },
        Item
    ),
    ok.

supervisor_crash(_Config) ->
    Error = crash,
    CrashReport = [
        {supervisor, {local, test}},
        {errorContext, Error},
        {reason, test_reason},
        {offender, []}
    ],
    Report =
        {report, #{
            label => {supervisor, Error},
            report => CrashReport
        }},
    Meta = #{
        domain => [otp, sasl],
        report_cb => fun supervisor:format_log/2,
        logger_formatter => #{title => "SUPERVISOR REPORT"},
        error_logger => #{
            tag => error_report, type => supervisor_report, report_cb => fun supervisor:format_log/2
        }
    },
    %% A stacktrace in metadata must not override the exception that the
    %% supervisor report already builds.
    MetaTrace = [{erlang, apply, 2, []}],
    LogItem = #{level => error, meta => Meta#{time => 0, stacktrace => MetaTrace}, msg => Report},
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    ct:pal(default, "Captured: ~p", [Item]),
    ?assertMatch(
        #{
            <<"level">> := <<"error">>,
            <<"timestamp">> := <<"1970-01-01T00:00:00", _/binary>>,
            <<"logger">> := <<"{supervisor,crash}">>,
            <<"logentry">> := #{
                <<"formatted">> := _
            },
            <<"exception">> := #{
                <<"values">> := [_Values]
            }
        },
        Item
    ),
    #{<<"exception">> := #{<<"values">> := [ExceptionValue]}} = Item,
    ?assertMatch(
        #{
            <<"type">> := <<"{supervisor,crash} {supervisor,{local,test}}">>,
            <<"value">> := <<"{reason,test_reason}">>
        },
        ExceptionValue
    ),
    ok.

proc_lib_crash(_Config) ->
    CrashReport = [
        {initial_call, {testmod, testfun, 0}},
        {pid, self()},
        {registered_name, fake},
        {process_label, testlabel},
        {error_info, {exit, test, []}},
        {ancestors, []},
        {message_queue_len, 0},
        {links, []},
        {dictionary, []}
    ],
    LinkReports = [],
    Report =
        {report, #{
            label => {proc_lib, crash},
            report => [CrashReport, LinkReports]
        }},
    Meta = #{
        domain => [otp, sasl],
        report_cb => fun proc_lib:report_cb/2,
        logger_formatter => #{title => "CRASH REPORT"},
        error_logger => #{tag => error_report, type => crash_report}
    },
    LogItem = #{level => warning, meta => Meta#{time => 0}, msg => Report},
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    ct:pal(default, "Captured: ~p", [Item]),
    ?assertMatch(
        #{
            <<"level">> := <<"warning">>,
            <<"timestamp">> := <<"1970-01-01T00:00:00", _/binary>>,
            <<"logger">> := <<"{proc_lib,crash}">>,
            <<"logentry">> := #{
                <<"formatted">> := _
            },
            <<"threads">> := #{
                <<"values">> := ThreadValues
            }
        } when length(ThreadValues) > 0,
        Item
    ),
    #{<<"threads">> := #{<<"values">> := [ExceptionValue]}} = Item,
    ?assertMatch(
        #{
            <<"id">> := _,
            <<"crashed">> := true,
            <<"current">> := true,
            <<"name">> := <<"fake {initial_call,{testmod,testfun,0}}">>,
            <<"stacktrace">> := _
        },
        ExceptionValue
    ),
    ok.

report_map(_Config) ->
    Report =
        #{
            reason => {party_error, {error, function_clause}},
            msg => <<"Controller crashed">>,
            stacktrace =>
                [
                    #{
                        arity => 1,
                        function => '-post_agreement/1-fun-0-',
                        line => 123,
                        module => signatures_sender_controller,
                        file => "/buildroot/src/signatures_sender_controller.erl"
                    },
                    #{
                        arity => 4,
                        function => '-new_transaction/3-fun-0-',
                        line => 180,
                        module => pgo,
                        file => "/buildroot/_build/default/lib/pgo/src/pgo.erl"
                    },
                    #{
                        arity => 5,
                        function => with_span,
                        line => 47,
                        module => otel_tracer_default,
                        file =>
                            "/buildroot/_build/default/lib/opentelemetry/src/otel_tracer_default.erl"
                    },
                    #{
                        arity => 1,
                        function => post_agreement,
                        line => 115,
                        module => signatures_sender_controller,
                        file => "/buildroot/src/signatures_sender_controller.erl"
                    },
                    #{
                        arity => 2,
                        function => execute,
                        line => 51,
                        module => nova_handler,
                        file =>
                            "/buildroot/_build/default/lib/nova/src/nova_handler.erl"
                    },
                    #{
                        arity => 3,
                        function => execute,
                        line => 310,
                        module => cowboy_stream_h,
                        file =>
                            "/buildroot/_build/default/lib/cowboy/src/cowboy_stream_h.erl"
                    },
                    #{
                        arity => 3,
                        function => request_process,
                        line => 299,
                        module => cowboy_stream_h,
                        file =>
                            "/buildroot/_build/default/lib/cowboy/src/cowboy_stream_h.erl"
                    },
                    #{
                        arity => 3,
                        function => init_p_do_apply,
                        line => 333,
                        module => proc_lib,
                        file => "proc_lib.erl"
                    }
                ],
            class => throw
        },
    LogItem = #{level => warning, meta => #{time => 0}, msg => {report, Report}},
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    ct:pal(default, "Captured:~n~p", [Item]),
    ?assertMatch(
        #{
            <<"level">> := <<"warning">>,
            <<"timestamp">> := <<"1970-01-01T00:00:00", _/binary>>,
            <<"logentry">> := #{
                <<"formatted">> :=
                    <<"<<\"Controller crashed\">>">>
            },
            <<"extra">> := #{
                <<"class">> := _,
                <<"stacktrace">> := _,
                <<"reason">> := _
            }
        },
        Item
    ),
    ok.

report_map_stacktrace_meta(_Config) ->
    Trace = [
        {rest_util_notification_info_content, incoming_share_from_user, 2, [
            {file, "/build/src/rest/util/rest_util_notification_info_content.erl"}, {line, 158}
        ]},
        {rest_util_notification_info_content, build_shared_user, 4, [
            {file, "/build/src/rest/util/rest_util_notification_info_content.erl"}, {line, 113}
        ]},
        {rest_util_notification_info_content, get_notification_info, 1, [
            {file, "/build/src/rest/util/rest_util_notification_info_content.erl"}, {line, 65}
        ]},
        {s2_maybe, lift, 1, [
            {file, "/build/_build/default/lib/stdlib2/src/s2_maybe.erl"}, {line, 76}
        ]},
        {greph, '-eval/3-fun-1-', 4, [
            {file, "/build/_build/default/lib/greph/src/greph.erl"}, {line, 178}
        ]},
        {otel_tracer_default, with_span, 5, [
            {file, "/build/_build/default/lib/opentelemetry/src/otel_tracer_default.erl"},
            {line, 47}
        ]},
        {lists, foldl_1, 3, [{file, "lists.erl"}, {line, 2471}]}
    ],
    Report = #{
        reason => {"Unknown failure reason", rest_util_notification_info_content},
        exception => {badmatch, false},
        resource => rest_util_notification_info_content
    },
    Meta = #{time => 0, stacktrace => Trace},
    LogItem = #{level => warning, meta => Meta, msg => {report, Report}},
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    ct:pal(default, "Captured:~n~p", [Item]),
    ?assertMatch(
        #{
            <<"level">> := <<"warning">>,
            <<"logentry">> := #{
                <<"formatted">> :=
                    <<"{\"Unknown failure reason\",rest_util_notification_info_content}">>
            },
            <<"exception">> := #{
                <<"values">> := [
                    #{
                        <<"type">> := <<"{badmatch,false}">>,
                        <<"value">> :=
                            <<"{\"Unknown failure reason\",rest_util_notification_info_content}">>,
                        <<"mechanism">> := #{
                            <<"type">> := <<"logging">>,
                            <<"handled">> := true
                        },
                        <<"stacktrace">> := #{
                            <<"frames">> := [
                                #{
                                    <<"function">> := <<"lists:foldl_1/3">>,
                                    <<"filename">> := <<"lists.erl">>,
                                    <<"lineno">> := 2471,
                                    <<"in_app">> := false
                                },
                                #{
                                    <<"function">> := <<"otel_tracer_default:with_span/5">>,
                                    <<"lineno">> := 47,
                                    <<"in_app">> := false
                                },
                                #{
                                    <<"function">> := <<"greph:'-eval/3-fun-1-'/4">>,
                                    <<"lineno">> := 178,
                                    <<"in_app">> := false
                                },
                                #{
                                    <<"function">> := <<"s2_maybe:lift/1">>,
                                    <<"lineno">> := 76,
                                    <<"in_app">> := false
                                },
                                #{
                                    <<"function">> :=
                                        <<"rest_util_notification_info_content:get_notification_info/1">>,
                                    <<"lineno">> := 65,
                                    <<"in_app">> := true
                                },
                                #{
                                    <<"function">> :=
                                        <<"rest_util_notification_info_content:build_shared_user/4">>,
                                    <<"lineno">> := 113,
                                    <<"in_app">> := true
                                },
                                #{
                                    <<"function">> :=
                                        <<"rest_util_notification_info_content:incoming_share_from_user/2">>,
                                    <<"filename">> :=
                                        <<"/build/src/rest/util/rest_util_notification_info_content.erl">>,
                                    <<"lineno">> := 158,
                                    <<"in_app">> := true
                                }
                            ]
                        }
                    }
                ]
            }
        },
        Item
    ),
    ok.

report_map_stacktrace_in_report(_Config) ->
    Trace = [
        {erlang, hd, [[]], [{error_info, #{module => erl_erts_errors}}]},
        {payment_consumer, handle_message, 1, [
            {file, "src/payments/payment_consumer.erl"}, {line, 40}
        ]},
        {erlang, apply, 2, []}
    ],
    Report = #{
        msg => <<"consumer crashed">>,
        % class takes precedence over exception_class when both are present
        class => error,
        exception_class => throw,
        stacktrace => Trace
    },
    LogItem = #{level => error, meta => #{time => 0}, msg => {report, Report}},
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    ct:pal(default, "Captured:~n~p", [Item]),
    ?assertMatch(
        #{
            <<"level">> := <<"error">>,
            <<"exception">> := #{
                <<"values">> := [
                    #{
                        <<"type">> := <<"error">>,
                        <<"value">> := <<"<<\"consumer crashed\">>">>,
                        <<"stacktrace">> := #{
                            <<"frames">> := [
                                #{<<"function">> := <<"erlang:apply/2">>},
                                #{
                                    <<"function">> := <<"payment_consumer:handle_message/1">>,
                                    <<"filename">> := <<"src/payments/payment_consumer.erl">>,
                                    <<"lineno">> := 40
                                },
                                #{<<"function">> := <<"erlang:hd/1">>}
                            ]
                        }
                    }
                ]
            },
            <<"extra">> := #{
                <<"class">> := _,
                <<"stacktrace">> := _
            }
        },
        Item
    ),
    ok.

format_log_stacktrace_meta(_Config) ->
    Trace = [
        {rest_auth_util, authenticate, 2, [
            {file, "/build/src/rest/rest_auth_util.erl"}, {line, 319}
        ]},
        {erlang, apply, 2, []}
    ],
    Meta = #{time => 0, class => throw, stacktrace => Trace},
    LogItem = #{level => error, meta => Meta, msg => {"auth failed for ~s", ["mobile-bankid"]}},
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    ct:pal(default, "Captured:~n~p", [Item]),
    ?assertMatch(
        #{
            <<"level">> := <<"error">>,
            <<"logentry">> := #{
                <<"formatted">> := <<"auth failed for mobile-bankid">>,
                <<"message">> := <<"auth failed for ~s">>
            },
            <<"exception">> := #{
                <<"values">> := [
                    #{
                        <<"type">> := <<"throw">>,
                        <<"value">> := <<"auth failed for mobile-bankid">>,
                        <<"mechanism">> := #{
                            <<"type">> := <<"logging">>,
                            <<"handled">> := true
                        },
                        <<"stacktrace">> := #{
                            <<"frames">> := [
                                #{<<"function">> := <<"erlang:apply/2">>, <<"in_app">> := false},
                                #{
                                    <<"function">> := <<"rest_auth_util:authenticate/2">>,
                                    <<"lineno">> := 319,
                                    <<"in_app">> := true
                                }
                            ]
                        }
                    }
                ]
            }
        },
        Item
    ),
    ok.

wait_for(EventId) ->
    receive
        {capture, EventId, Payload} ->
            Payload
    end.
