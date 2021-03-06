(*---------------------------------------------------------------------------
   Copyright (c) 2017 The b0 programmers. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
   %%NAME%% %%VERSION%%
  ---------------------------------------------------------------------------*)

(** Measuring time. See {!B0.Time}. *)

(** {1 Monotonic wall-clock time} *)

type span
val zero : span
val one : span
val add : span -> span -> span
val abs_diff : span -> span -> span
val to_ns : span -> float
val to_uint64_ns : span -> int64
val of_uint64_ns : int64 -> span
val pp_span : Format.formatter -> span -> unit
val pp_span_uint_ns : Format.formatter -> span -> unit
val compare_span : span -> span -> int

type counter
val counter : unit -> counter
val count : counter -> span

(** {1 CPU time} *)

type cpu
val cpu_zero : cpu
val cpu_utime_s : cpu -> float
val cpu_stime_s : cpu -> float
val cpu_children_utime_s : cpu -> float
val cpu_children_stime_s : cpu -> float

type cpu_counter
val cpu_counter : unit -> cpu_counter
val cpu_count : cpu_counter -> cpu

(** {1 Pretty-print float seconds *)

val pp_float_s : Format.formatter -> float -> unit

(*---------------------------------------------------------------------------
   Copyright (c) 2017 The b0 programmers

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)
