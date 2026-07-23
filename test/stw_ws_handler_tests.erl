%%%-------------------------------------------------------------------
%% @doc EUnit tests for the Phase 0 WebSocket message logic.
%%
%% These tests exercise the pure encode/decode and message-handling
%% behaviour without opening real sockets. As the handler grows, prefer
%% keeping decision logic in pure functions so it stays testable.
%% @end
%%%-------------------------------------------------------------------
-module(stw_ws_handler_tests).

-include_lib("eunit/include/eunit.hrl").

json_roundtrip_test() ->
    Term = #{<<"type">> => <<"ping">>,
             <<"seq">> => 1,
             <<"payload">> => #{}},
    Encoded = iolist_to_binary(json:encode(Term)),
    Decoded = json:decode(Encoded),
    ?assertEqual(<<"ping">>, maps:get(<<"type">>, Decoded)),
    ?assertEqual(1, maps:get(<<"seq">>, Decoded)).

decode_valid_json_test() ->
    {ok, Msg} = stw_ws_handler:decode(<<"{\"type\":\"ping\",\"seq\":7}">>),
    ?assertEqual(<<"ping">>, maps:get(<<"type">>, Msg)),
    ?assertEqual(7, maps:get(<<"seq">>, Msg)).

decode_invalid_json_test() ->
    ?assertMatch({error, _}, stw_ws_handler:decode(<<"not json{">>)).
