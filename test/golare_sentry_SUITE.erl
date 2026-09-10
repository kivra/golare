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
            report_map_nested_exception,
            report_map_oversized_exception,
            latin1_string_log,
            report_cb_ignoring_limits,
            report_map_binary_message,
            nested_binaries_are_elided,
            binaries_behind_a_list_are_elided,
            elision_cost_does_not_follow_the_term,
            format_log_params_budget,
            format_log_multiline_type,
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

report_map_nested_exception(_Config) ->
    Trace = [
        {bankday_server, bankdays_before, 2, [
            {file, "/build/src/kivra_core/bankday_server.erl"}, {line, 27}
        ]},
        {gen_server, call, 2, [{file, "gen_server.erl"}, {line, 1221}]}
    ],
    Exception =
        {exit,
            {noproc,
                {gen_server, call, [
                    bankday_server, {bankdays_before, 0, <<"2026-10-01T00:00:00Z">>}
                ]}}},
    Report = #{
        reason => {exit, is_authorized},
        exception => Exception,
        resource => rest_company_offboard
    },
    LogItem = #{
        level => warning, meta => #{time => 0, stacktrace => Trace}, msg => {report, Report}
    },
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    ct:pal(default, "Captured:~n~p", [Item]),
    %% The call arguments differ per request, and exception.type is the one
    %% event field Relay never scrubs, so the depth has to stop above them.
    ?assertMatch(
        #{
            <<"exception">> := #{
                <<"values">> := [
                    #{
                        <<"type">> :=
                            <<"{exit,{noproc,{gen_server,call,[bankday_server,{...}]}}}">>,
                        <<"value">> := <<"{exit,is_authorized}">>
                    }
                ]
            }
        },
        Item
    ),
    ok.

report_map_oversized_exception(_Config) ->
    Trace = [{rest_company_offboard, mm_status, 2, [{file, "rest.erl"}, {line, 1}]}],
    Fault = binary:copy(<<"SOAP-ENV:Server fault. ">>, 1000),
    Report = #{
        reason => {error, {fault, <<"SOAP-ENV:Server">>, Fault}},
        exception => {badmatch, {error, {fault, <<"SOAP-ENV:Server">>, Fault}}},
        soap_response => Fault
    },
    LogItem = #{
        level => warning, meta => #{time => 0, stacktrace => Trace}, msg => {report, Report}
    },
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    #{
        <<"exception">> := #{<<"values">> := [#{<<"type">> := Type, <<"value">> := Value}]},
        <<"extra">> := #{<<"soap_response">> := Extra},
        <<"logentry">> := #{<<"formatted">> := Formatted}
    } = Item,
    ct:pal(default, "type: ~p~nvalue: ~p", [Type, Value]),
    ?assertEqual(
        <<"{badmatch,{error,{fault,<<\"...\">>,<<\"...\">>}}}">>, Type
    ),
    %% truncate/2 emits at most Limit characters plus a three character
    %% marker, against the limits the handler defines for each field.
    ?assert(string:length(Value) =< 4096 + 3),
    ?assert(string:length(Extra) =< 1024 + 3),
    ?assert(string:length(Formatted) =< 8192 + 3),
    %% ...and the fields still carry the fault, rather than being gutted.
    ?assert(string:length(Value) > 1000),
    ?assert(string:length(Extra) > 1000),
    ok.

latin1_string_log(_Config) ->
    Trace = [{rest_content, get, 2, [{file, "rest_content.erl"}, {line, 1}]}],
    %% Not valid UTF-8: unicode:characters_to_binary/1 answers with an error
    %% tuple rather than raising, and that tuple used to reach the encoder.
    Latin1 = <<"betalningsp", 229, "minnelse">>,
    LogItem = #{
        level => warning,
        meta => #{time => 0, stacktrace => Trace},
        msg => {string, Latin1}
    },
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    ct:pal(default, "Captured:~n~p", [Item]),
    ?assertMatch(
        #{
            <<"logentry">> := #{<<"formatted">> := <<"betalningsp\xc3\xa5minnelse">>},
            <<"exception">> := #{
                <<"values">> := [#{<<"value">> := <<"betalningsp\xc3\xa5minnelse">>}]
            }
        },
        Item
    ),
    ok.

report_cb_ignoring_limits(_Config) ->
    %% The config handed to a report_cb/2 is advisory, and application code is
    %% free to ignore chars_limit, as this one does.
    ReportFun = fun(#{payload := Payload}, _Cfg) -> ["payload: ", Payload] end,
    Report = #{payload => binary:copy(<<"x">>, 20000)},
    LogItem = #{
        level => error,
        meta => #{time => 0, report_cb => ReportFun},
        msg => {report, Report}
    },
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    #{<<"logentry">> := #{<<"formatted">> := Formatted}} = Item,
    ?assert(string:length(Formatted) =< 8192 + 3),
    ?assert(string:length(Formatted) > 8000),
    ?assertMatch(<<"payload: xxx", _/binary>>, Formatted),
    ok.

report_map_binary_message(_Config) ->
    Trace = [{cashier_client, check, 1, [{file, "cashier_client.erl"}, {line, 1}]}],
    %% A flat binary message has no nesting for the type's depth limit to
    %% bound, and the depth would otherwise cut it at around 22 bytes.
    Report = #{message => <<"Check call to cashier failed">>, tenant => <<"1234">>},
    LogItem = #{level => error, meta => #{time => 0, stacktrace => Trace}, msg => {report, Report}},
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    ct:pal(default, "Captured:~n~p", [Item]),
    ?assertMatch(
        #{
            <<"exception">> := #{
                <<"values">> := [
                    #{
                        <<"type">> := <<"<<\"Check call to cashier failed\">>">>,
                        <<"value">> := <<"<<\"Check call to cashier failed\">>">>
                    }
                ]
            }
        },
        Item
    ),
    ok.

format_log_params_budget(_Config) ->
    %% Relay budgets the whole params array at 2048 bytes, and non-ASCII text
    %% spends two bytes per character, so both multipliers are exercised here.
    Param = binary:copy(<<"p\xc3\xa5minnelse "/utf8>>, 200),
    Params = lists:duplicate(8, Param),
    Format = lists:flatten(lists:duplicate(8, "~ts ")),
    LogItem = #{level => warning, meta => #{time => 0}, msg => {Format, Params}},
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    #{<<"logentry">> := #{<<"params">> := Reported}} = Item,
    Total = lists:sum([byte_size(P) || P <- Reported]),
    ct:pal(default, "~b params, ~b bytes total", [length(Reported), Total]),
    ?assert(Total =< 2048 + 16),
    %% The budget is spent on the first params rather than shared into
    %% uselessness, and the array still says it was cut.
    ?assert(byte_size(hd(Reported)) > 1000),
    ?assertEqual(<<"...">>, lists:last(Reported)),
    ok.

format_log_multiline_type(_Config) ->
    Trace = [{payment_icon, upload, 1, [{file, "payment_icon.erl"}, {line, 1}]}],
    %% Sentry puts the type inside a Slack link label, where a newline ends
    %% the markup and exposes the raw <url|*...*> syntax.
    Format = "Failed to upload payment option icon~nReason: ~p",
    LogItem = #{
        level => error,
        meta => #{time => 0, stacktrace => Trace},
        msg => {Format, [timeout]}
    },
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    #{<<"exception">> := #{<<"values">> := [#{<<"type">> := Type}]}} = Item,
    ct:pal(default, "type: ~p", [Type]),
    ?assertEqual(nomatch, binary:match(Type, [<<"\n">>, <<"\r">>])),
    ?assertEqual(<<"Failed to upload payment option icon Reason: timeout">>, Type),
    ok.

nested_binaries_are_elided(_Config) ->
    Trace = [{rest_user, lookup, 1, [{file, "rest_user.erl"}, {line, 1}]}],
    %% exception.type is the one event field Relay never scrubs, and it is
    %% the Slack alert's title, so a binary inside the term - which is where
    %% a personnummer or an address ends up - must not reach it at any depth.
    Report = #{exception => {badmatch, {error, <<"19850101-1234 not found">>}}},
    LogItem = #{level => error, meta => #{time => 0, stacktrace => Trace}, msg => {report, Report}},
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    #{<<"exception">> := #{<<"values">> := [#{<<"type">> := Type}]}} = Item,
    ct:pal(default, "type: ~p", [Type]),
    ?assertEqual(<<"{badmatch,{error,<<\"...\">>}}">>, Type),
    ?assertEqual(nomatch, binary:match(Type, <<"19850101">>)),
    ok.

binaries_behind_a_list_are_elided(_Config) ->
    Trace = [{rest_user, lookup, 1, [{file, "rest_user.erl"}, {line, 1}]}],
    %% A list spends depth per element, so a container reached past one used
    %% to escape the bound entirely - the traversal ran to the end of the
    %% term, inside log/2, on a report shape as ordinary as a proplist.
    Nested = lists:foldl(fun(_, Acc) -> {nest, Acc} end, <<"19850101-1234">>, lists:seq(1, 40)),
    Report = #{exception => {badmatch, [{k, Nested} || _ <- lists:seq(1, 15)]}},
    LogItem = #{level => error, meta => #{time => 0, stacktrace => Trace}, msg => {report, Report}},
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {_, Item} = wait_for(EventId),
    #{<<"exception">> := #{<<"values">> := [#{<<"type">> := Type}]}} = Item,
    ct:pal(default, "type: ~p", [Type]),
    ?assertEqual(nomatch, binary:match(Type, <<"19850101">>)),
    ?assert(byte_size(Type) =< 128 + 3),
    ok.

elision_cost_does_not_follow_the_term(_Config) ->
    %% The clamp is about work, not output: without it the traversal runs off
    %% the end of the bound and walks the whole term, while producing exactly
    %% the same title. So measure the cost of two reports that are identical
    %% down to the elision depth and differ only far below it.
    Shallow = nest_report(40),
    Deep = nest_report(200000),
    ShallowCost = log_reductions(Shallow),
    DeepCost = log_reductions(Deep),
    ct:pal(default, "shallow ~b reds, deep ~b reds", [ShallowCost, DeepCost]),
    ?assert(DeepCost < 5 * ShallowCost),
    ok.

nest_report(Depth) ->
    Nested = lists:foldl(fun(_, Acc) -> {nest, Acc} end, <<"19850101-1234">>, lists:seq(1, Depth)),
    #{exception => {badmatch, [{k, Nested} || _ <- lists:seq(1, 15)]}}.

log_reductions(Report) ->
    Trace = [{rest_user, lookup, 1, [{file, "rest_user.erl"}, {line, 1}]}],
    LogItem = #{level => error, meta => #{time => 0, stacktrace => Trace}, msg => {report, Report}},
    {reductions, Before} = process_info(self(), reductions),
    {ok, EventId} = golare_logger_h:log(LogItem, #{}),
    {reductions, After} = process_info(self(), reductions),
    {_, _} = wait_for(EventId),
    After - Before.

wait_for(EventId) ->
    receive
        {capture, EventId, Payload} ->
            Payload
    end.
