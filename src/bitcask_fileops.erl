%% -------------------------------------------------------------------
%%
%% Copyright (c) 2010-2017 Basho Technologies, Inc.
%% Copyright (c) 2022-2025 Workday, Inc.
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

%% @doc Basic file i/o operations for bitcask.
-module(bitcask_fileops).

-export([
    create_file/3,
    open_file/1,
    open_file/2,
    close/1,
    close_all/1,
    close_for_writing/1,
    data_file_tstamps/1,
    write/5,
    read/3,
    sync/1,
    delete/1,
    fold/3,
    fold_keys/4,
    collect_keys_from_hintfile/1,
    mk_filename/2,
    filename/1,
    hintfile_name/1,
    file_tstamp/1,
    check_write/4,
    un_write/1,
    recreate_hintfile/2,
    delete_hintfile/1,
    maybe_open_hintfile/2,
    write_entry_to_hintfile/7,
    close_hintfile/1
]).
-export([
    read_file_info/1,
    write_file_info/2,
    is_file/1
]).

%% Make sure only a consistent set of test macros are defined so we don't
%% have to keep checking them all repeatedly.
-ifndef(TEST).
-undef(EQC).
-undef(PULSE).
-else.
-ifndef(EQC).
-undef(PULSE).
-endif.
-endif.

-ifdef(PULSE).
-compile([
    {parse_transform, pulse_instrument},
    {pulse_side_effect, [
        {file, '_', '_'},
        {prim_file, '_', '_'},
        {bitcask_nifs, '_', '_'}
    ]}
]).
-include_lib("pulse_otp/include/pulse_otp.hrl").
-endif.
-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-endif.

-ifdef(TEST).
-compile([export_all, nowarn_export_all]).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/logger.hrl").
-include("bitcask.hrl").

%% @doc Open a new file for writing.
%% Called on a Dirname, will open a fresh file in that directory.
-spec create_file(Dirname :: string(), Opts :: [any()],
                  reference()) ->
                         {ok, filestate()} | {error, {term(), term()}}.

create_file(DirName, Opts0, Keydir) ->
    Opts = [create|Opts0],
    case get_create_lock(DirName) of
        {ok, Lock} ->
            try
                {ok, Newest} = bitcask_nifs:increment_file_id(Keydir),

                Filename = mk_filename(DirName, Newest),
                ok = ensure_dir(Filename),

                FinalOpts = add_sync_strategy(Opts),

                {ok, FD} = bitcask_io:file_open(Filename, FinalOpts),
                HintFD = open_hintfile(Filename, FinalOpts),
                {ok, #filestate{mode = read_write,
                                filename = Filename,
                                tstamp = file_tstamp(Filename),
                                hintfd = HintFD, fd = FD, ofs = 0}}
            catch Error:Reason ->
                    %% if we fail somehow, do we need to nuke any partial
                    %% state?
                    {error, {Error, Reason}}
            after
                bitcask_lockops:release(Lock)
            end;
        Else ->
            Else
    end.

-spec add_sync_strategy(Opts :: list()) -> list().
add_sync_strategy(Opts) ->
    case bitcask:get_opt(sync_strategy, Opts) of
        o_sync ->
            [o_sync | Opts];
        _ ->
            Opts
    end.

get_create_lock(DirName) ->
    get_create_lock(DirName, 100).

get_create_lock(_DirName, 0) ->
    error(lock_failure);
get_create_lock(DirName, N) ->
    timer:sleep(100-N),
    case bitcask_lockops:acquire(create, DirName) of
        {ok, Lock} ->
            {ok, Lock};
        {error, locked} ->
            get_create_lock(DirName, N - 1);
        {error, _} = Else ->
            Else
    end.


%% @doc Open an existing file for reading.
%% Called with fully-qualified filename.
-spec open_file(Filename :: string())
                -> {ok, filestate()} | {error, any()}.
open_file(Filename) ->
    open_file(Filename, readonly).

-spec open_file(Filename :: string(), append | readonly)
                -> {ok, filestate()} | {error, any()}.
open_file(Filename, append) ->
    case bitcask_io:file_open(Filename, []) of
        {ok, FD} ->
            case bitcask_io:file_position(FD, {eof, 0}) of
                {ok, 0} ->
                    % File was deleted and we just opened a new one, undo.
                    bitcask_io:file_close(FD),
                    _ = file:delete(Filename),
                    {error, enoent};
                {ok, Ofs} ->
                    DefaultFileState = #filestate{mode = read_write,
                                                  filename = Filename,
                                                  tstamp = file_tstamp(Filename),
                                                  fd = FD,
                                                  hintfd = undefined,
                                                  hintcrc = 0,
                                                  ofs = Ofs
                                                 },

                    {ok, maybe_reopen_hintfile_for_appending(DefaultFileState)}
            end;
        {error, _Reason} = Err ->
            Err
    end;
open_file(Filename, readonly) ->
    case bitcask_io:file_open(Filename, [readonly]) of
        {ok, FD} ->
            {ok, #filestate{mode = read_only,
                            filename = Filename, tstamp = file_tstamp(Filename),
                            fd = FD, ofs = 0}};
        {error, Reason} ->
            {error, Reason}
    end.

% @doc Reopens hintfile for appending. If we cannot open the hintfile for
% any reason, we delete it so that it does not become out-of-sync
% with the data file.
-spec maybe_reopen_hintfile_for_appending(filestate()) -> filestate().
maybe_reopen_hintfile_for_appending(FS) ->
    case maybe_open_hintfile(FS, []) of
        #filestate{hintfd=undefined} ->
            ?LOG_WARNING(
                "Could not reopen hintfile for appending, hint not set: ~0tp",
                [FS]),
            FS;
        #filestate{hintfd=HintFD, filename = Filename} = HintFS ->
            HintFilename = hintfile_name(Filename),
            {ok, HintI} = read_file_info(HintFilename),
            HintSize = HintI#file_info.size,
            case bitcask_io:file_position(HintFD, HintSize) of
                {ok, 0} ->
                    bitcask_io:file_close(HintFD),
                    _ = file:delete(HintFilename),
                    ?LOG_ERROR(
                        "Could not reopen hintfile for appending, file empty,"
                        " deleting: ~0tp", [HintFilename]),
                    FS;
                {ok, _FileSize} ->
                    case prepare_hintfile_for_append(HintFD) of
                        {undefined, _} ->
                            _ = file:delete(HintFilename),
                            ?LOG_ERROR(
                                "Could not reopen hintfile for appending,"
                                " CRC empty or corrupt, deleting: ~0tp",
                                [HintFilename]),
                            FS;
                        {HintFD, HintCRC} ->
                            HintFS#filestate{
                              hintfd = HintFD,
                              hintcrc = HintCRC
                             }
                    end
            end
    end.

% Removes the final CRC record so more records can be added to the file.
-spec prepare_hintfile_for_append(HintFD :: file:fd()) ->
    {HintFD :: file:fd(), CRC :: crc()} |
    {undefined, 0}.
prepare_hintfile_for_append(HintFD) ->
    case bitcask_io:file_position(HintFD,
                                  {eof, -?HINT_RECORD_SZ}) of
        {ok, _} ->
            case read_crc(HintFD) of
                error ->
                    bitcask_io:file_close(HintFD),
                    {undefined, 0};
                HintCRC ->
                    bitcask_io:file_position(HintFD,
                                             {eof, -?HINT_RECORD_SZ}),
                    bitcask_io:file_truncate(HintFD),
                    {HintFD, HintCRC}
            end;
        _ ->
            bitcask_io:file_close(HintFD),
            {undefined, 0}
    end.

%% @doc Use when done writing a file.  (never open for writing again)
-spec close(filestate() | fresh | undefined) -> ok.
close(fresh) -> ok;
close(undefined) -> ok;
close(State = #filestate{ fd = FD }) ->
    _ = close_hintfile(State),
    bitcask_io:file_close(FD),
    ok.

%% @doc Use when closing multiple files.  (never open for writing again)
-spec close_all([filestate()]) -> ok.
close_all(FileStates) ->
    lists:foreach(fun ?MODULE:close/1, FileStates),
    ok.

%% @doc Close a file for writing, but leave it open for reads.
-spec close_for_writing(filestate()) -> filestate().
close_for_writing(State = #filestate{ mode = read_write, fd = Fd }) ->
    S2 = close_hintfile(State),
    bitcask_io:file_sync(Fd),
    S2#filestate { mode = read_only }.

close_hintfile(State = #filestate { hintfd = undefined }) ->
    State;
close_hintfile(State = #filestate { hintfd = HintFd, hintcrc = HintCRC }) ->
    %% Write out CRC check at end of hint file.  Write with an empty key, zero
    %% timestamp and offset as large as the file format supports so opening with
    %% an older version of bitcask will just reject the record at the end of the
    %% hintfile and otherwise work normally.
    Iolist = hintfile_entry(<<>>, <<>>, 0, 0, ?MAXOFFSET_V2, HintCRC),
    _ = bitcask_io:file_write(HintFd, Iolist),
    _ = bitcask_io:file_sync(HintFd),
    _ = bitcask_io:file_close(HintFd),
    State#filestate { hintfd = undefined, hintcrc = 0 }.

%% Build a list of {tstamp, filename} for all files in the directory that
%% match our regex.
-spec data_file_tstamps(Dirname :: string()) -> [{integer(), string()}].
data_file_tstamps(Dirname) ->
    case file:list_dir(Dirname) of
        {ok, Files} ->
            lists:foldl(
              fun(Filename, Acc) ->
                      case string:tokens(Filename, ".") of
                          [TSString, _, "data"] ->
                              [{list_to_integer(TSString),
                                filename:join(Dirname, Filename)}
                                | Acc];
                          _ ->
                              Acc
                      end
              end,
              [], Files)
    end.

%% @doc Use only after merging, to permanently delete a data file.
-spec delete(string()) -> ok | {error, atom()}.
delete(FN) ->
    _ = file:delete(FN),
    case has_hintfile(FN) of
        true ->
            file:delete(hintfile_name(FN));
        false ->
            ok
    end.

%% @doc Write a Key-named binary data field ("Value") to the Filestate.
-spec write(filestate(),
            Key :: binary(), Value :: binary(), Meta :: binary(), Tstamp :: integer()) ->
        {ok,filestate(), Offset :: integer(), Size :: integer()} |
        {error, read_only}.
write(#filestate{ mode = read_only }, _K, _V, _M, _Tstamp) ->
    {error, read_only};
write(Filestate=#filestate{fd = FD, hintcrc = HintCRC0, ofs = Offset},
      Key, Value, Meta, Tstamp) ->
    KeySz = size(Key),
    true = (KeySz =< ?MAXKEYSIZE),
    ValueSz = size(Value),
    true = (ValueSz =< ?MAXVALSIZE),
    MetaSz = size(Meta),
    true = (MetaSz =< ?MAXVALSIZE),

    %% Setup io_list for writing -- avoid merging binaries if we can help it
    Bytes0 = [<<Tstamp:?TSTAMPFIELD>>, <<KeySz:?KEYSIZEFIELD>>,
              <<ValueSz:?VALSIZEFIELD>>, Key, Value],
    Bytes  = [<<(erlang:crc32(Bytes0)):?CRCSIZEFIELD>> | Bytes0],
    %% Store the full entry in the data file
    try
        ok = bitcask_io:file_pwrite(FD, Offset, Bytes),
        TotalSz = iolist_size(Bytes),

                                     TombInt = case bitcask:is_tombstone(Value) of
                                                   true  -> 1;
                                                   false -> 0
                                               end,
        {LHBytes, HintCRC} = write_entry_to_hintfile(Filestate, Key, Tstamp, Meta, TombInt,
                                                     Offset, TotalSz),

        {ok, Filestate#filestate{ofs = Offset + TotalSz,
                                 hintcrc = HintCRC,
                                 l_ofs = Offset,
                                 l_hbytes = LHBytes,
                                 l_hintcrc = HintCRC0}, Offset, TotalSz}
    catch
        error:{badmatch,Error} ->
            Error
    end.

-spec write_entry_to_hintfile(
    filestate(), Key :: binary(), timestamp(), Meta :: binary(), 0 | 1,
    non_neg_integer(), non_neg_integer()) -> {non_neg_integer(), crc()}.
write_entry_to_hintfile(#filestate{hintfd = undefined}, _, _, _, _, _, _) ->
    {0, 0};
write_entry_to_hintfile(#filestate{fd = _, hintfd = HintFD,
                                   hintcrc = HintCRC0},
                        Key, Tstamp, Meta, TombInt, Offset, TotalSz
                       ) ->
    Iolist = hintfile_entry(Key, Meta, Tstamp, TombInt, Offset, TotalSz),

    ok = bitcask_io:file_write(HintFD, Iolist),
    {iolist_size(Iolist), erlang:crc32(HintCRC0, Iolist)}.

%% WARNING: We can only undo the last write.
un_write(FS=#filestate{fd = FD,
                       l_ofs = LastOffset
                      }) ->
    {ok, _O2} = bitcask_io:file_position(FD, LastOffset),
    ok = bitcask_io:file_truncate(FD),
    {ok, 0} = bitcask_io:file_position(FD, 0),

    FS1 = un_write_hintfile(FS),
    {ok, FS1#filestate{ofs = LastOffset}}.

-spec un_write_hintfile(filestate()) -> filestate().
un_write_hintfile(FS=#filestate{hintfd=undefined}) ->
    FS;
un_write_hintfile(FS=#filestate{l_hbytes = LastHintBytes,
                                l_hintcrc = LastHintCRC,
                                hintfd = HintFD
                               }) ->
    {ok, _HO2} = bitcask_io:file_position(HintFD, {cur, -LastHintBytes}),
    ok = bitcask_io:file_truncate(HintFD),
    FS#filestate{hintcrc = LastHintCRC}.

%% @doc Given an Offset and Size, get the corresponding k/v from Filename.
-spec read(Filename :: string() | filestate(), Offset :: integer(),
           Size :: integer()) ->
        {ok, Key :: binary(), Value :: binary()} |
        {error, bad_crc} | {error, term()}.
read(Filename, Offset, Size) when is_list(Filename) ->
    case open_file(Filename) of
        {ok, Fstate} ->
            read(Fstate, Offset, Size);
        {error, Reason} ->
            {error, Reason}
    end;
read(#filestate { fd = FD }, Offset, Size) ->
    case bitcask_io:file_pread(FD, Offset, Size) of
        {ok, <<Crc32:?CRCSIZEFIELD/unsigned, Bytes/binary>>} ->
            %% Verify the CRC of the data
            case erlang:crc32(Bytes) of
                Crc32 ->
                    %% Unpack the actual data
                    <<_Tstamp:?TSTAMPFIELD,
                     KeySz:?KEYSIZEFIELD, ValueSz:?VALSIZEFIELD,
                     Key:KeySz/bytes, Value:ValueSz/bytes>> = Bytes,
                    {ok, Key, Value};
                _BadCrc ->
                    {error, bad_crc}
            end;
        eof ->
            {error, eof};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Call the OS's fsync(2) system call on the cask and hint files.
-spec sync(#filestate{}) -> ok.
sync(#filestate { mode = read_write, fd = Fd, hintfd = undefined }) ->
    ok = bitcask_io:file_sync(Fd);
sync(#filestate { mode = read_write, fd = Fd, hintfd = HintFd }) ->
    ok = bitcask_io:file_sync(Fd),
    ok = bitcask_io:file_sync(HintFd).

-spec fold(fresh | #filestate{}, value_fold_fun(), any()) ->
        any() | {error, any()}.
fold(fresh, _Fun, Acc) -> Acc;
fold(#filestate { fd=Fd, filename=Filename, tstamp=FTStamp }, Fun, Acc0) ->
    %% TODO: Add some sort of check that this is a read-only file
    ok = bitcask_io:file_seekbof(Fd),
    case fold_file_loop(Fd, regular, fun fold_int_loop/5, Fun, Acc0,
                        {Filename, FTStamp, 0, 0}) of
        {error, {truncated_file, Acc}} ->
            Acc;
        {error, Reason} ->
            {error, Reason};
        Acc -> Acc
    end.

% Fold keys will always use a data file to iterate.
% Use `collect_keys_from_hintfile/1` when wanting to traverse hintfile.
-spec fold_keys(fresh | filestate(), key_fold_fun(), any(), fold_key_options()) ->
        any() | {error, any()}.
fold_keys(fresh, _Fun, Acc, _Opts) -> Acc;
fold_keys(FS=#filestate{}, Fun, Acc, Opts) ->
    fold_keys_loop(FS, Fun, Acc, Opts).

-spec collect_keys_from_hintfile(filestate()) -> list(any()) |
                                                 {error, undefined_hintfile} |
                                                 {error, invalid_hintfile}.
collect_keys_from_hintfile(#filestate{hintfd = undefined}) ->
    {error, undefined_hintfile};
collect_keys_from_hintfile(FS) ->
    case fold_hintfile(FS, {{0, 0}, []}) of
        {error, Error} ->
            ?LOG_ERROR("Could not collect keys from hintfile ~p  : ~p", [FS, Error]),
            {error, invalid_hintfile};
        Keys ->
            lists:reverse(Keys)
    end.

-spec mk_filename(string(), integer()) -> string().
mk_filename(Dirname, Tstamp) ->
    filename:join(Dirname,
                  lists:concat([integer_to_list(Tstamp),".bitcask.data"])).

-spec filename(filestate()) -> string().
filename(#filestate { filename = Fname }) ->
    Fname.

-spec hintfile_name(string() | filestate()) -> string().
hintfile_name(Filename) when is_list(Filename) ->
    filename:rootname(Filename, ".data") ++ ".hint";
hintfile_name(#filestate { filename = Fname }) ->
    hintfile_name(Fname).

-spec file_tstamp(filestate() | string()) -> integer().
file_tstamp(#filestate{tstamp=Tstamp}) ->
    Tstamp;
file_tstamp(Filename) when is_list(Filename) ->
    case filename:basename(Filename, ".bitcask.data") of
        BaseName when is_list(BaseName) ->
            list_to_integer(BaseName);
        BaseName when is_binary(BaseName) ->
            binary_to_integer(BaseName)
    end.

-spec check_write(filestate() | fresh, binary(), non_neg_integer(), integer()) ->
      fresh | wrap | ok.
check_write(fresh, _Key, _ValSize, _MaxSize) ->
    %% for the very first write, special-case
    fresh;
check_write(#filestate { ofs = Offset }, Key, ValSize, MaxSize) ->
    Size = ?HEADER_SIZE + size(Key) + ValSize,
    case (Offset + Size) > MaxSize of
        true ->
            wrap;
        false ->
            ok
    end.

-spec has_hintfile(string() | filestate()) -> boolean().
has_hintfile(Filename) ->
    is_file(hintfile_name(Filename)).

-spec delete_hintfile(filestate()) -> filestate().
delete_hintfile(#filestate{hintfd = undefined} = FS) ->
    FS#filestate{hintfd = undefined, hintcrc = 0};
delete_hintfile(#filestate{hintfd = HintFD} = FS) ->
    bitcask_io:file_close(HintFD),
    _ = file:delete(bitcask_fileops:hintfile_name(FS)),
    FS#filestate{hintfd = undefined, hintcrc = 0}.

% `maybe_open_hintfile/2` should be ran prior to this.,
-spec recreate_hintfile(filestate(), list()) -> filestate().
recreate_hintfile(#filestate{hintfd = undefined} = FS, Opts) ->
    FinalOpts = add_sync_strategy([create | Opts]),
    HintFD1 = open_hintfile(FS, FinalOpts),
    FS#filestate{hintfd = HintFD1, hintcrc = 0};
recreate_hintfile(#filestate{hintfd = HintFD} = FS, Opts) ->
    bitcask_io:file_close(HintFD),
    HintName = bitcask_fileops:hintfile_name(FS),

    _ = file:delete(HintName),
    FinalOpts = add_sync_strategy([create | Opts]),

    HintFD1 = open_hintfile(FS, FinalOpts),
    FS#filestate{hintfd = HintFD1, hintcrc = 0}.

-spec read_crc(Fd :: file:fd()) -> crc() | error.
read_crc(Fd) ->
    case bitcask_io:file_read(Fd, ?HINT_RECORD_SZ) of
        {ok, <<0:?TSTAMPFIELD,
               0:?KEYSIZEFIELD,
               ExpectCRC:?TOTALSIZEFIELD,
               _TombInt:?TOMBSTONEFIELD_V2,
               (?MAXOFFSET_V2):?OFFSETFIELD_V2>>} ->
            ExpectCRC;
        _ -> error
    end.


%% ===================================================================
%% Internal functions
%% ===================================================================

-spec fold_int_loop(
    Bytes :: binary(),
    Fun :: value_fold_fun(),
    Acc :: term(),
    Consumed :: non_neg_integer(),
    FoldState :: fold_state()
) ->
    {done, NewAcc :: term()} |
    {more, NewAcc :: term(), NewConsumed :: non_neg_integer(),
           NewFoldState :: fold_state()}.
fold_int_loop(_Bytes, _Fun, Acc, _Consumed, {Filename, _, Offset, 20}) ->
    ?LOG_ERROR("fold_loop: CRC error limit at file ~0tp offset ~0tp",
                           [Filename, Offset]),
    {done, Acc};
fold_int_loop(<<Crc32:?CRCSIZEFIELD, Tstamp:?TSTAMPFIELD,
                KeySz:?KEYSIZEFIELD, ValueSz:?VALSIZEFIELD,
                Key:KeySz/bytes, Value:ValueSz/bytes, Rest/binary>>,
              Fun, Acc0, Consumed0,
              {Filename, FTStamp, Offset, CrcSkipCount}) ->
    TotalSz = KeySz + ValueSz + ?HEADER_SIZE,
    case erlang:crc32([<<Tstamp:?TSTAMPFIELD, KeySz:?KEYSIZEFIELD,
                         ValueSz:?VALSIZEFIELD>>, Key, Value]) of
        Crc32 ->
            PosInfo = {Filename, FTStamp, Offset, TotalSz},
            Acc = Fun(Key, Value, Tstamp, PosInfo, Acc0),
            fold_int_loop(Rest, Fun, Acc, Consumed0 + TotalSz,
                          {Filename, FTStamp, Offset + TotalSz,
                           CrcSkipCount});
        _ ->
            ?LOG_ERROR("fold_loop: CRC error at file ~ts offset ~0tp, "
                                   "skipping ~0tp bytes",
                                   [Filename, Offset, TotalSz]),
            fold_int_loop(Rest, Fun, Acc0, Consumed0 + TotalSz,
                          {Filename, FTStamp, Offset + TotalSz,
                           CrcSkipCount + 1})
    end;
fold_int_loop(_Bytes, _Fun, Acc, Consumed, Args) ->
    {more, Acc, Consumed, Args}.

-spec fold_keys_loop(
    FileState :: filestate(),
    Fun :: key_fold_fun(),
    Acc0 :: term(),
    Opts :: [{meta_getter, fun((binary()) -> term())} | term()]
) -> term() | {error, term()}.
fold_keys_loop(#filestate{fd=Fd, filename=Filename, tstamp=FTStamp},
               Fun, Acc0, Opts) ->
    case bitcask_io:file_position(Fd, 0) of
        {ok, 0} -> ok;
        Other -> error(Other)
    end,

    MetaGetter = proplists:get_value(meta_getter, Opts, fun meta_getter_noop/1),

    case fold_file_loop(Fd, regular, fun fold_keys_int_loop/5, Fun, Acc0,
                        {MetaGetter, {Filename, FTStamp, 0, 0}}) of
        {error, {_, Acc}} -> Acc;
        {error, Reason} ->
            {error, Reason};
        Acc -> Acc
    end.

fold_keys_int_loop(_Bytes, _Fun, Acc, _Consumed, {Filename, _, Offset, 20}) ->
    ?LOG_ERROR("fold_loop: CRC error limit at file ~0tp offset ~0tp",
                           [Filename, Offset]),
    {done, Acc};
fold_keys_int_loop(<<Crc32:?CRCSIZEFIELD, Tstamp:?TSTAMPFIELD,
                     KeySz:?KEYSIZEFIELD, ValueSz:?VALSIZEFIELD,
                     Key:KeySz/bytes, Value:ValueSz/bytes, Rest/binary>>,
                   Fun, Acc0, Consumed0,
                   {MetaGetter, {Filename, FTStamp, Offset, CrcSkipCount}}) ->
    TotalSz = KeySz + ValueSz + ?HEADER_SIZE,
    case erlang:crc32([<<Tstamp:?TSTAMPFIELD, KeySz:?KEYSIZEFIELD,
                         ValueSz:?VALSIZEFIELD>>, Key, Value]) of
        Crc32 ->
            PosInfo = {Offset, TotalSz},
            KeyPlus = case bitcask:is_tombstone(Value) of
                          true  -> {tombstone, Key};
                          false -> Key
                      end,

            Meta = MetaGetter(Value),
            Acc = Fun({KeyPlus, Meta, Tstamp, PosInfo}, Acc0),
            fold_keys_int_loop(Rest, Fun, Acc, Consumed0 + TotalSz,
                               {MetaGetter, {Filename, FTStamp, Offset + TotalSz,
                                CrcSkipCount}});
        _ ->
            ?LOG_ERROR("fold_loop: CRC error at file ~ts offset ~0tp, "
                                   "skipping ~0tp bytes",
                                   [Filename, Offset, TotalSz]),
            fold_keys_int_loop(Rest, Fun, Acc0, Consumed0 + TotalSz,
                               {MetaGetter, {Filename, FTStamp, Offset + TotalSz,
                                CrcSkipCount + 1}})
    end;
fold_keys_int_loop(_Bytes, _Fun, Acc, Consumed, Args) ->
    {more, Acc, Consumed, Args}.

-spec fold_hintfile(filestate(), any())
        -> any() | {error, {fold_hintfile, any()}} | {error, undefined_hintfile}.
fold_hintfile(#filestate{hintfd=undefined}, _Acc0) ->
    {error, undefined_hintfile};
fold_hintfile(#filestate{hintfd=HintFD, filename=FileName} = FS, Acc0) ->
    try
        HintFile = hintfile_name(FS),
        case bitcask_io:file_position(HintFD, 0) of
            {ok, 0} -> ok;
            Other -> error(Other)
        end,

        {ok, DataI} = read_file_info(HintFile),
        DataSize = DataI#file_info.size,

        case fold_file_loop(HintFD, hint, fun fold_hintfile_loop/4,
                            Acc0, {DataSize, HintFile}) of
            {{ExpectCRC, ExpectCRC}, Acc} ->
                Acc;
            {{_HintCRC, _ExpectCRC}, _Acc} ->
                {error, {fold_hintfile, crc_invalid}};
            {error, Reason} ->
                {error, {fold_hintfile, Reason}}
        end
    catch _Class:ReasonErr:Stacktrace ->
        ?LOG_ERROR("Could not fold over hintfile ~p, with FD ~p due to: ~p ~p ~n",
                    [FileName, HintFD, ReasonErr, Stacktrace]),
        {error, ReasonErr}
    after
        bitcask_io:file_close(HintFD)
    end.

-spec fold_hintfile_loop(
    Bytes :: binary(),
    Acc :: {{crc(), crc()}, [{Key :: binary(), Meta :: binary(), timestamp(), hint_pos_info()}]},
    Consumed :: non_neg_integer(),
    FoldState :: fold_state() )
        -> {error, atom()} |
            {done, NewAcc :: term()} |
            {more, NewAcc :: term(), NewConsumed :: non_neg_integer(),
                   NewFoldState :: fold_state()}.
fold_hintfile_loop(_, _, _, {undefined, _HintFile}) ->
    {error, undefined_file_size};
fold_hintfile_loop(<<0:?TSTAMPFIELD, 0:?KEYSIZEFIELD, _MetaSz:?METASIZEFIELD,
                     ExpectCRC:?TOTALSIZEFIELD,
                     _TombInt:?TOMBSTONEFIELD_V2, (?MAXOFFSET_V2):?OFFSETFIELD_V2>>,
                   {{CRC, _}, Acc0}, Consumed, _Args) ->
    Acc = {{CRC, ExpectCRC}, Acc0},
    {done, Acc, Consumed + ?HINT_RECORD_SZ};
%% main work loop here, containing the full match of hint record and key.
%% if it gets a match, it proceeds to recurse over the rest of the big
%% binary
fold_hintfile_loop(<<Tstamp:?TSTAMPFIELD, KeySz:?KEYSIZEFIELD,
                     MetaSz:?METASIZEFIELD,
                     TotalSz:?TOTALSIZEFIELD,
                     TombInt:?TOMBSTONEFIELD_V2, Offset:?OFFSETFIELD_V2,
                     Key:KeySz/bytes, Meta:MetaSz/bytes, Rest/binary>>,
                   {{CRC0, PlaceholderCRC}, KeyAcc0} = Acc0, Consumed0, {DataSize, HintFile} = Args) ->
    case Consumed0 + ?HINT_RECORD_SZ + KeySz + MetaSz =< DataSize of
        true ->
            PosInfo = {Offset, TotalSz},
            KeyPlus = if TombInt == 1 -> {tombstone, Key};
                         true         -> Key
                      end,

            KeyAcc = [{KeyPlus, Meta, Tstamp, PosInfo} | KeyAcc0],
            Iolist = hintfile_entry(Key, Meta, Tstamp, TombInt, Offset, TotalSz),
            CRC = erlang:crc32(CRC0, Iolist),
            Acc = {{CRC, PlaceholderCRC}, KeyAcc},
            Consumed = KeySz + MetaSz + ?HINT_RECORD_SZ + Consumed0,
            fold_hintfile_loop(Rest, Acc, Consumed, Args);
        false ->
            ?LOG_WARNING("Hintfile '~ts' contains pointer ~0tp ~0tp "
                                     "that is greater than total data size ~0tp",
                                     [HintFile, Offset, TotalSz, DataSize]),
            {error, {crc_invalid, Acc0}}
    end;
%% catchall case where we don't get enough bytes from fold_file_loop
fold_hintfile_loop(_Bytes, Acc0, Consumed0, Args) ->
    {more, Acc0, Consumed0, Args}.

-spec fold_file_loop(
    Fd :: file:fd(),
    Type :: hint,
    FoldFn :: hint_file_fold_fun(),
    Acc :: term(),
    Args :: fold_state() )
        -> term() | {error, term()}.
fold_file_loop(Fd, hint, FoldFn, Acc, Args) ->
    fold_file_loop(Fd, hint, FoldFn, undefined, Acc, Args, none, ?CHUNK_SIZE).

%% @doc scaffolding for faster folds over large files.
%% The somewhat tricky thing here is the FoldFn, which is a /6
%% that does all the actual work.  see fold_hintfile_loop as a
%% commented example
-spec fold_file_loop(
    Fd :: file:fd(),
    Type :: regular | hint,
    FoldFn :: data_file_fold_fun() | hint_file_fold_fun(),
    IntFoldFn :: function() | undefined,
    Acc :: term(),
    Args :: fold_state() )
        -> term() | {error, term()}.
fold_file_loop(Fd, Type, FoldFn, IntFoldFn, Acc, Args) ->
    fold_file_loop(Fd, Type, FoldFn, IntFoldFn, Acc, Args, none, ?CHUNK_SIZE).

-spec fold_file_loop(
    Fd :: file:fd(),
    Type :: regular | hint,
    FoldFn :: data_file_fold_fun() | hint_file_fold_fun(),
    IntFoldFn :: function() | undefined,
    Acc :: term(),
    Args :: fold_state(),
    Prev :: binary() | none,
    ChunkSz :: pos_integer() )
        -> term() | {error, term()}.
fold_file_loop(Fd, Type, FoldFn, IntFoldFn, Acc0, Args0, Prev0, ChunkSz0) ->
    %% analyze what happened in the last loop to determine whether or
    %% not to change the read size. This is an optimization for large values
    %% in datafile folds and key folds
    {Prev, ChunkSz}
        = case Prev0 of
              none -> {<<>>, ChunkSz0};
              Other ->
                  CS = case byte_size(Other) of
                           %% to avoid having to rescan the same
                           %% binaries over and over again.
                           N when N >= ?MAX_CHUNK_SIZE ->
                               ?MAX_CHUNK_SIZE;
                           N when N > ChunkSz0 ->
                               ChunkSz0 * 2;
                           _ -> ChunkSz0
                       end,
                  {Other, CS}
          end,
    case bitcask_io:file_read(Fd, ChunkSz) of
        {ok, <<Bytes0/binary>>} ->
            Bytes = <<Prev/binary, Bytes0/binary>>,
            Results = case IntFoldFn of
                undefined ->
                    FoldFn(Bytes, Acc0, 0, Args0);
                _ ->
                    FoldFn(Bytes, IntFoldFn, Acc0, 0, Args0)
            end,
            case Results of
                %% foldfuns should return more when they don't have enough
                %% bytes to satisfy their main binary match.
                {more, Acc, Consumed, Args} ->
                    Rest =
                        case Consumed > byte_size(Bytes) of
                            true -> <<>>;
                            false ->
                                <<_:Consumed/bytes, R/binary>> = Bytes,
                                R
                        end,
                    fold_file_loop(Fd, Type, FoldFn, IntFoldFn,
                                   Acc, Args, Rest, ChunkSz);
                %% the done two tuple is returned when we want to be
                %% unconditionally successfully finished,
                %% i.e. trailing data is a non-fatal error
                {done, Acc} ->
                    Acc;
                %% three tuple done requires full consumption of all
                %% bytes given to the internal fold function, to
                %% satisfy the pre-existing semantics of hintfile
                %% folds.
                {done, Acc, Consumed} ->
                    case Consumed =:= byte_size(Bytes) of
                        true -> Acc;
                        false ->
                            {error, {partial_fold, Consumed, byte_size(Bytes)}}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        eof ->
            case byte_size(Prev) > 0 of
                true ->
                    {error, {truncated_file, Acc0}};
                _ ->
                    Acc0
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec maybe_open_hintfile(filestate(), list()) -> filestate().
maybe_open_hintfile(FS, Opts) ->
    case  (catch open_hintfile(FS, Opts)) of
        couldnt_open_hintfile ->
            FS;
        HintFD ->
            FS#filestate{hintfd=HintFD}
    end.

open_hintfile(Filename, FinalOpts) ->
    open_hintfile(Filename, FinalOpts, 10).

open_hintfile(_Filename, _FinalOpts, 0) ->
    throw(couldnt_open_hintfile);
open_hintfile(Filename, FinalOpts, Count) ->
    case bitcask_io:file_open(hintfile_name(Filename), FinalOpts) of
        {ok, FD} ->
            FD;
        {error, enoent} ->
            throw(couldnt_open_hintfile);
        {error, eexist} ->
            timer:sleep(50),
            open_hintfile(Filename, FinalOpts, Count - 1)
    end.

hintfile_entry(Key, Meta, Tstamp, TombInt, Offset, TotalSz) ->
    KeySz = size(Key),
    MetaSz = size(Meta),
    [<<Tstamp:?TSTAMPFIELD, KeySz:?KEYSIZEFIELD, MetaSz:?METASIZEFIELD, TotalSz:?TOTALSIZEFIELD,
       TombInt:?TOMBSTONEFIELD_V2, Offset:?OFFSETFIELD_V2>>, Key, Meta].

%% ===================================================================
%% file/filelib avoidance code.
%% ===================================================================

read_file_info(FileName) ->
    prim_file:read_file_info(FileName).

write_file_info(FileName, Info) ->
    prim_file:write_file_info(FileName, Info).

is_file(File) ->
    case read_file_info(File) of
        {ok, #file_info{type=regular}} ->
            true;
        {ok, #file_info{type=directory}} ->
            true;
        _ ->
            false
    end.

is_dir(File) ->
    case read_file_info(File) of
        {ok, #file_info{type=directory}} ->
            true;
        _ ->
            false
    end.

ensure_dir("/") ->
    ok;
ensure_dir(F) ->
    Dir = filename:dirname(F),
    case is_dir(Dir) of
        true ->
            ok;
        false when Dir =:= F ->
            %% Protect against infinite loop
            {error,einval};
        false ->
            _ = ensure_dir(Dir),
            %% this is rare enough that the serialization
            %% isn't super important, maybe
            case file:make_dir(Dir) of
                {error,eexist}=EExist ->
                    case is_dir(Dir) of
                        true ->
                            ok;
                        false ->
                            EExist
                    end;
                Err ->
                    Err
            end
    end.

meta_getter_noop(_) -> <<>>.
