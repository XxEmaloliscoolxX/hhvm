(*
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *
 *)

type key = OpaqueDigest.t

module IntVal = struct
  type t = int

  let description = "Test_IntVal"
end

let test_add_remove
    (module IntHeap : SharedMem.Heap with type value = int and type key = string)
    () =
  assert (SharedMem.SMTelemetry.hh_removed_count () = 0);
  IntHeap.add "a" 4;
  assert (SharedMem.SMTelemetry.hh_removed_count () = 0);
  assert (IntHeap.mem "a");
  IntHeap.remove_batch (IntHeap.KeySet.singleton "a");
  assert (not @@ IntHeap.mem "a");
  assert (SharedMem.SMTelemetry.hh_removed_count () = 1)

module TestNoCache =
  SharedMem.Heap
    (SharedMem.ImmediateBackend (SharedMem.NonEvictable)) (StringKey)
    (IntVal)

let tests () =
  let list = [("test_add_remove", test_add_remove (module TestNoCache))] in
  let setup_test (name, test) =
    ( name,
      fun () ->
        let num_workers = 0 in
        let handle =
          SharedMem.init
            ~num_workers
            {
              SharedMem.global_size = 16;
              heap_size = 1024;
              hash_table_pow = 3;
              shm_dirs = [];
              shm_use_sharded_hashtbl = false;
              shm_enable_eviction = false;
              shm_max_evictable_bytes = 0;
              shm_min_avail = 0;
              log_level = 0;
              sample_rate = 0.0;
              compression = 0;
            }
        in
        ignore (handle : SharedMem.handle);
        test ();
        true )
  in
  List.map setup_test list

let () = Unit_test.run_all (tests ())
