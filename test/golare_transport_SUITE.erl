-module(golare_transport_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("stdlib/include/assert.hrl").

all() ->
    [
        capture_when_down,
        log_when_down
    ].

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
