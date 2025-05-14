%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018-2025 Workday, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(bitcask_lockops_tests).

%% Warning: Without 'export_all', the first test will fail (that is, it
%% succeeds in acquiring the lock on the second call). This happens even if
%% the tests and external-vm functions are explicitly exported. Clearly
%% something funky is going on in eunit.hrl.
-compile([export_all, nowarn_export_all]).

%% Comment this out to see output from the spawned process.
-define(NODEBUG, true).

-include_lib("eunit/include/eunit.hrl").
-include("bitcask.hrl").

lock_cannot_be_obtained_on_already_locked_file_within_same_os_process_test() ->
    Dir = create_test_dir(?FUNCTION_NAME),
    Filename = bitcask_lockops:lock_filename(write,Dir),
    ok = file_delete(Filename),
    ok = file:write_file(Filename, ""),
    {ok, _Lock} = bitcask_lockops:acquire(write, Dir),
    ?assertMatch({error, locked}, bitcask_lockops:acquire(write, Dir)).

lock_can_be_obtained_on_already_locked_file_is_unlocked_test() ->
    Dir = create_test_dir(?FUNCTION_NAME),
    Filename = bitcask_lockops:lock_filename(write,Dir),
    ok = file_delete(Filename),
    ok = file:write_file(Filename, ""),
    {ok, Lock} = bitcask_lockops:acquire(write, Dir),
    bitcask_lockops:release(Lock),
    ?assertMatch({ok, _}, bitcask_lockops:acquire(write, Dir)).

lock_cannot_be_obtained_on_already_locked_file_across_os_process_test() ->
    DbDir = filename:absname(create_test_dir(?FUNCTION_NAME)),
    %% start another erlang vm that will open the DB and obtain a write
    %% lock, then, when we try to obtain a write lock on the current vm
    %% it should fail.
    %% ToDo: Post OTP 24 use the 'peer' module, too much hassle before then.
    {?MODULE, _, TBeam} = code:get_object_code(?MODULE),
    {bitcask, _, BBeam} = code:get_object_code(bitcask),
    Tbin = filename:dirname(TBeam),
    Bbin = filename:dirname(BBeam),
    Erl = filename:join([code:root_dir(), "bin", "erl"]),
    Cmd = lists:flatten([
        "'", Erl, "' -pa '", Bbin, "' -pa '", Tbin, "' -noinput -noshell -eval"
        " 'bitcask_lockops_tests:bitcask_locker_vm_main(\"", DbDir, "\").'"
    ]),
    ?debugFmt("~n= COMMAND: ~ts", [Cmd]),
    ExtPid = erlang:spawn_link(?MODULE, run_vm_process, [Cmd]),
    MonRef = erlang:monitor(process, ExtPid),
    timer:sleep(1000),
    DB = bitcask:open(DbDir, [read_write]),
    ?assertMatch({error, {error, locked}}, bitcask:put(DB, <<"k">>, <<"v">>, <<"meta">>)),
    receive
        {'DOWN', MonRef, _Type, _Object, _Info} = _Msg ->
            ?debugFmt("~n= RECEIVE: ~p~n", [_Msg])
    end.

run_vm_process(Command) ->
    _Output = ?cmd(Command),
    ?debugFmt("~n= CMD OUTPUT: ~s~n", [_Output]).

%% entry function for another vm to lock a bitcask DB
bitcask_locker_vm_main(DbDir) ->
    case (catch bitcask:open(DbDir, [read_write, {open_timeout, 1000}])) of
        {error, Error} ->
            io:format("ERROR: ~0tp", [Error]);
        DB ->
            %% DB is locked on the first write operation
            ok = bitcask:put(DB, <<"k">>, <<"v">>, <<"meta">>),
            io:format("~0tp", [os:getpid()]),
            timer:sleep(3000),
            erlang:halt()
    end.

file_delete(Filename) ->
    case file:delete(Filename) of
        ok ->
            ok;
        {error, enoent} ->
            ok
    end.

-spec create_test_dir(Label :: atom() | string()) -> string().
%% Creates a new, empty, directory for testing.
create_test_dir(Label) ->
    bitcask:setup_testfolder(io_lib:format("bc.lockops.~s", [Label])).
