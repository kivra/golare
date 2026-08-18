-module(golare_transport_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("stdlib/include/assert.hrl").

all() ->
    [
        capture_when_down,
        log_when_down,
        capture_when_busy,
        log_when_busy,
        log_when_scope_raises
    ].

end_per_testcase(_TestCase, _Config) ->
    case whereis(golare_transport) of
        undefined ->
            ok;
        Stub ->
            unregister(golare_transport),
            exit(Stub, kill)
    end,
    persistent_term:erase({golare, process_scope}),
    ok.

%% A transport that never replies, i.e. alive but behind.
busy_transport() ->
    Stub = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    true = register(golare_transport, Stub),
    Stub.

%% The transport is down before golare starts and while it restarts.
%% Capturing must report down, not exit the calling process.
capture_when_down(_Config) ->
    ?assertEqual({ok, down}, golare_transport:capture({event, #{}})).

%% The same holds all the way from the logger handler, on both the
%% event path and the sdk crash fallback path.
log_when_down(_Config) ->
    LogItem = #{level => error, meta => #{time => 0}, msg => {string, "transport down"}},
    ?assertEqual({ok, down}, golare_logger_h:log(LogItem, #{})),
    %% Missing meta time crashes event_timestamp/1, forcing the fallback.
    Broken = LogItem#{meta => #{}},
    ?assertEqual({ok, down}, golare_logger_h:log(Broken, #{})).

%% The transport is alive but not replying, so the call times out. Capturing
%% must drop the event rather than exit the logging process. Costs one call
%% timeout (5s) by design: the timeout is what is under test.
capture_when_busy(_Config) ->
    _Stub = busy_transport(),
    ?assertEqual({ok, dropped}, golare_transport:capture({event, #{}})).

%% The same seen from the logger handler: no exit escapes log/2, so OTP has
%% no reason to remove the handler.
log_when_busy(_Config) ->
    _Stub = busy_transport(),
    LogItem = #{level => error, meta => #{time => 0}, msg => {string, "transport busy"}},
    ?assertEqual({ok, dropped}, golare_logger_h:log(LogItem, #{})).

%% A process_scope fun that raises breaks capture_event/1 on both the event
%% path and the sdk crash fallback path. The handler must still return
%% cleanly; without the fallback guard the second failure escapes log/2 and
%% OTP removes the handler.
log_when_scope_raises(_Config) ->
    persistent_term:put({golare, process_scope}, #{user => fun() -> error(boom) end}),
    LogItem = #{level => error, meta => #{time => 0}, msg => {string, "scope raises"}},
    ?assertEqual(ok, golare_logger_h:log(LogItem, #{})).
