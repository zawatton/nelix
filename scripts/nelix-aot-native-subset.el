;;; nelix-aot-native-subset.el --- Native-eligible Nelix AOT subset -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Small native-eligible kernels for Doc 25 M3.  The full line-protocol
;; manifest engine remains portable Elisp for now; this file proves the
;; native path for the core set-comparison operation using integer bitsets.

;;; Code:

(unless (fboundp 'declare-function)
  (defmacro declare-function (&rest _ignored) nil))

(declare-function str-len "ext:nelisp-native" (text))
(declare-function str-byte-at "ext:nelisp-native" (text pos))
(declare-function mut-str-make-empty "ext:nelisp-native" (out capacity))
(declare-function mut-str-push-byte "ext:nelisp-native" (out byte))
(declare-function mut-str-finalize "ext:nelisp-native" (out dest))

(defun nelix-aot-native-missing-count8 (desired installed)
  "Return count of names present in DESIRED but absent from INSTALLED.
DESIRED and INSTALLED are 8-bit name-set masks.  This intentionally avoids
local mutation, loops, `ash', and `lognot' so the current `.neln' native
proof harness can execute it without external runtime helpers."
  (+ (if (and (not (= (logand desired 1) 0)) (= (logand installed 1) 0)) 1 0)
     (if (and (not (= (logand desired 2) 0)) (= (logand installed 2) 0)) 1 0)
     (if (and (not (= (logand desired 4) 0)) (= (logand installed 4) 0)) 1 0)
     (if (and (not (= (logand desired 8) 0)) (= (logand installed 8) 0)) 1 0)
     (if (and (not (= (logand desired 16) 0)) (= (logand installed 16) 0)) 1 0)
     (if (and (not (= (logand desired 32) 0)) (= (logand installed 32) 0)) 1 0)
     (if (and (not (= (logand desired 64) 0)) (= (logand installed 64) 0)) 1 0)
     (if (and (not (= (logand desired 128) 0)) (= (logand installed 128) 0)) 1 0)))

(defun nelix-aot-native-extra-count8 (desired installed)
  "Return count of names present in INSTALLED but absent from DESIRED."
  (nelix-aot-native-missing-count8 installed desired))

(defun nelix-aot-native-ok-code8 (desired installed)
  "Return 1 when DESIRED and INSTALLED masks are equal, otherwise 0."
  (if (= (+ (nelix-aot-native-missing-count8 desired installed)
            (nelix-aot-native-extra-count8 desired installed))
         0)
      1
    0))

(defun nelix-aot-native-string-len (text)
  "Return byte length of TEXT through the native string argument lane."
  (str-len text))

(defun nelix-aot-native-string-first-byte (text)
  "Return first byte of TEXT through the native string argument lane."
  (str-byte-at text 0))

(defun nelix-aot-native-match-byte (text pos byte)
  "Return 1 when TEXT byte at POS is BYTE, otherwise 0."
  (if (= (str-byte-at text pos) byte) 1 0))

(defun nelix-aot-native-protocol-prefix-code (text)
  "Return 1 when TEXT starts with the Nelix AOT protocol version."
  (if (= (nelix-aot-native-match-byte text 0 78) 1)
      (if (= (nelix-aot-native-match-byte text 1 69) 1)
          (if (= (nelix-aot-native-match-byte text 2 76) 1)
              (if (= (nelix-aot-native-match-byte text 3 73) 1)
                  (if (= (nelix-aot-native-match-byte text 4 88) 1)
                      (if (= (nelix-aot-native-match-byte text 5 45) 1)
                          (if (= (nelix-aot-native-match-byte text 6 65) 1)
                              (if (= (nelix-aot-native-match-byte text 7 79) 1)
                                  (if (= (nelix-aot-native-match-byte text 8 84) 1)
                                      (if (= (nelix-aot-native-match-byte text 9 45) 1)
                                          (if (= (nelix-aot-native-match-byte text 10 77) 1)
                                              (if (= (nelix-aot-native-match-byte text 11 65) 1)
                                                  (if (= (nelix-aot-native-match-byte text 12 78) 1)
                                                      (if (= (nelix-aot-native-match-byte text 13 73) 1)
                                                          (if (= (nelix-aot-native-match-byte text 14 70) 1)
                                                              (if (= (nelix-aot-native-match-byte text 15 69) 1)
                                                                  (if (= (nelix-aot-native-match-byte text 16 83) 1)
                                                                      (if (= (nelix-aot-native-match-byte text 17 84) 1)
                                                                          (if (= (nelix-aot-native-match-byte text 18 45) 1)
                                                                              (if (= (nelix-aot-native-match-byte text 19 86) 1)
                                                                                  (if (= (nelix-aot-native-match-byte text 20 49) 1) 1 0)
                                                                                0)
                                                                            0)
                                                                        0)
                                                                    0)
                                                                0)
                                                            0)
                                                        0)
                                                    0)
                                                0)
                                            0)
                                        0)
                                    0)
                                0)
                            0)
                        0)
                    0)
                0)
            0)
        0)
    0))

(defun nelix-aot-native-record-tag-code (text pos)
  "Return the line-protocol record tag code at TEXT POS.
Codes are: target=1, pin=2, installed=3, end=4, unknown=0."
  (if (= (str-byte-at text pos) 116)
      (if (= (str-byte-at text (+ pos 1)) 97)
          (if (= (str-byte-at text (+ pos 2)) 114)
              (if (= (str-byte-at text (+ pos 3)) 103)
                  (if (= (str-byte-at text (+ pos 4)) 101)
                      (if (= (str-byte-at text (+ pos 5)) 116) 1 0)
                    0)
                0)
            0)
        0)
    (if (= (str-byte-at text pos) 105)
        (if (= (str-byte-at text (+ pos 1)) 110)
            (if (= (str-byte-at text (+ pos 2)) 115) 3 0)
          0)
      (if (= (str-byte-at text pos) 112)
          (if (= (str-byte-at text (+ pos 1)) 105)
              (if (= (str-byte-at text (+ pos 2)) 110) 2 0)
            0)
        (if (= (str-byte-at text pos) 101)
            (if (= (str-byte-at text (+ pos 1)) 110)
                (if (= (str-byte-at text (+ pos 2)) 100) 4 0)
              0)
          0)))))

(defun nelix-aot-native-count-byte-loop (text byte i n count)
  "Tail-recursive native scanner for BYTE in TEXT."
  (if (>= i n)
      count
    (nelix-aot-native-count-byte-loop
     text byte (+ i 1) n
     (if (= (str-byte-at text i) byte)
         (+ count 1)
       count))))

(defun nelix-aot-native-count-byte (text byte)
  "Return the number of BYTE occurrences in TEXT."
  (nelix-aot-native-count-byte-loop text byte 0 (str-len text) 0))

(defun nelix-aot-native-count-tag-loop (text wanted i n count)
  "Tail-recursive native scanner for line-protocol tag WANTED."
  (if (>= i n)
      count
    (nelix-aot-native-count-tag-loop
     text wanted (+ i 1) n
     (if (= (nelix-aot-native-record-tag-code text i) wanted)
         (+ count 1)
       count))))

(defun nelix-aot-native-count-tag (text wanted)
  "Return the number of WANTED line-protocol record tags in TEXT."
  (nelix-aot-native-count-tag-loop text wanted 0 (str-len text) 0))

(defun nelix-aot-native-find-byte-loop (text byte i n)
  "Tail-recursive native scanner returning the first BYTE offset or N."
  (if (>= i n)
      n
    (if (= (str-byte-at text i) byte)
        i
      (nelix-aot-native-find-byte-loop text byte (+ i 1) n))))

(defun nelix-aot-native-find-byte (text byte start)
  "Return the first BYTE offset at or after START, or the string length."
  (nelix-aot-native-find-byte-loop text byte start (str-len text)))

(defun nelix-aot-native-field-end-loop (text i n)
  "Return the offset where a TAB, LF, or EOF terminates a field."
  (if (>= i n)
      n
    (if (= (str-byte-at text i) 9)
        i
      (if (= (str-byte-at text i) 10)
          i
        (nelix-aot-native-field-end-loop text (+ i 1) n)))))

(defun nelix-aot-native-field-end (text start)
  "Return the field end offset from START."
  (nelix-aot-native-field-end-loop text start (str-len text)))

(defun nelix-aot-native-field-byte-sum-loop (text i n sum)
  "Tail-recursive byte sum for one field."
  (if (>= i n)
      sum
    (if (= (str-byte-at text i) 9)
        sum
      (if (= (str-byte-at text i) 10)
          sum
        (nelix-aot-native-field-byte-sum-loop
         text (+ i 1) n (+ sum (str-byte-at text i)))))))

(defun nelix-aot-native-field-byte-sum (text start)
  "Return the byte sum of the field starting at START."
  (nelix-aot-native-field-byte-sum-loop text start (str-len text) 0))

(defun nelix-aot-native-digit-value (byte)
  "Return decimal value for BYTE, or -1 when BYTE is not a digit."
  (if (and (>= byte 48) (<= byte 57))
      (- byte 48)
    -1))

(defun nelix-aot-native-field-small-uint-loop (text i n value)
  "Return unsigned integer parsed from one field starting at I."
  (if (>= i n)
      value
    (if (= (str-byte-at text i) 9)
        value
      (if (= (str-byte-at text i) 10)
          value
        (if (< (nelix-aot-native-digit-value (str-byte-at text i)) 0)
            value
          (nelix-aot-native-field-small-uint-loop
           text (+ i 1) n
           (+ (* value 10)
              (nelix-aot-native-digit-value (str-byte-at text i)))))))))

(defun nelix-aot-native-field-small-uint (text start)
  "Return a small unsigned integer parsed from the field at START."
  (nelix-aot-native-field-small-uint-loop text start (str-len text) 0))

(defun nelix-aot-native-add-bit8 (mask bit)
  "Return MASK with BIT set, avoiding duplicate additions."
  (if (= bit 0)
      mask
    (if (= (logand mask bit) 0)
        (+ mask bit)
      mask)))

(defun nelix-aot-native-merge-mask8 (mask bits)
  "Return MASK with every bit from BITS added through `add-bit8'."
  (nelix-aot-native-add-bit8
   (nelix-aot-native-add-bit8
    (nelix-aot-native-add-bit8
     (nelix-aot-native-add-bit8
      (nelix-aot-native-add-bit8
       (nelix-aot-native-add-bit8
        (nelix-aot-native-add-bit8
         (nelix-aot-native-add-bit8
          mask
          (if (= (logand bits 1) 0) 0 1))
         (if (= (logand bits 2) 0) 0 2))
        (if (= (logand bits 4) 0) 0 4))
       (if (= (logand bits 8) 0) 0 8))
      (if (= (logand bits 16) 0) 0 16))
     (if (= (logand bits 32) 0) 0 32))
    (if (= (logand bits 64) 0) 0 64))
   (if (= (logand bits 128) 0) 0 128)))

(defun nelix-aot-native-name-bit-from-sum (sum)
  "Map a small package-name byte SUM to an 8-bit proof mask bit."
  (if (= sum 530)
      1
    (if (= sum 761)
        2
      (if (= sum 202)
          4
        (if (= sum 311) 8 0)))))

(defun nelix-aot-native-bit-from-id (id)
  "Map a compact package ID to an 8-bit proof mask bit."
  (if (= id 1)
      1
    (if (= id 2)
        2
      (if (= id 3)
          4
        (if (= id 4) 8 0)))))

(defun nelix-aot-native-line-first-field-bit (text pos)
  "Return the proof bit for the first payload field on the line at POS."
  (nelix-aot-native-name-bit-from-sum
   (nelix-aot-native-field-byte-sum
    text
    (+ (nelix-aot-native-find-byte text 9 pos) 1))))

(defun nelix-aot-native-line-first-field-id-bit (text pos)
  "Return the proof bit for the first numeric payload field at POS."
  (nelix-aot-native-bit-from-id
   (nelix-aot-native-field-small-uint
    text
    (+ (nelix-aot-native-find-byte text 9 pos) 1))))

(defun nelix-aot-native-next-field-start-from-end (text end n)
  "Return the field start after END, or N when END is not a TAB."
  (if (>= end n)
      n
    (if (= (str-byte-at text end) 9)
        (+ end 1)
      n)))

(defun nelix-aot-native-next-field-start (text start n)
  "Return the next field start after the field at START, capped by N."
  (nelix-aot-native-next-field-start-from-end
   text
   (nelix-aot-native-field-end text start)
   n))

(defun nelix-aot-native-field-mask-loop (text start n mask)
  "Accumulate package-name bits for fields from START until N."
  (if (>= start n)
      mask
    (nelix-aot-native-field-mask-loop
     text
     (nelix-aot-native-next-field-start text start n)
     n
      (nelix-aot-native-add-bit8
       mask
       (nelix-aot-native-name-bit-from-sum
        (nelix-aot-native-field-byte-sum text start))))))

(defun nelix-aot-native-field-id-mask-loop (text start n mask)
  "Accumulate package ID bits for fields from START until N."
  (if (>= start n)
      mask
    (nelix-aot-native-field-id-mask-loop
     text
     (nelix-aot-native-next-field-start text start n)
     n
     (nelix-aot-native-add-bit8
      mask
      (nelix-aot-native-bit-from-id
       (nelix-aot-native-field-small-uint text start))))))

(defun nelix-aot-native-target-candidate-mask-at (text pos)
  "Return candidate package mask for a target line at POS.
The first target payload field is the display/name field.  Candidate
fields start after it and continue until LF."
  (nelix-aot-native-field-mask-loop
   text
   (nelix-aot-native-next-field-start
    text
    (+ (nelix-aot-native-find-byte text 9 pos) 1)
    (nelix-aot-native-find-byte text 10 pos))
   (nelix-aot-native-find-byte text 10 pos)
   0))

(defun nelix-aot-native-target-candidate-id-mask-at (text pos)
  "Return candidate package ID mask for a target-id line at POS."
  (nelix-aot-native-field-id-mask-loop
   text
   (nelix-aot-native-next-field-start
    text
    (+ (nelix-aot-native-find-byte text 9 pos) 1)
    (nelix-aot-native-find-byte text 10 pos))
   (nelix-aot-native-find-byte text 10 pos)
   0))

(defun nelix-aot-native-mask-for-tag-loop (text wanted i n mask)
  "Tail-recursive scan that accumulates first-field bits for WANTED tags."
  (if (>= i n)
      mask
    (nelix-aot-native-mask-for-tag-loop
     text wanted (+ i 1) n
     (if (= (nelix-aot-native-record-tag-code text i) wanted)
         (nelix-aot-native-add-bit8
          mask
          (nelix-aot-native-line-first-field-bit text i))
       mask))))

(defun nelix-aot-native-mask-for-tag (text wanted)
  "Return the package-name proof mask for WANTED line-protocol tags."
  (nelix-aot-native-mask-for-tag-loop text wanted 0 (str-len text) 0))

(defun nelix-aot-native-id-mask-for-tag-loop (text wanted i n mask)
  "Tail-recursive scan that accumulates first-field ID bits for WANTED tags."
  (if (>= i n)
      mask
    (nelix-aot-native-id-mask-for-tag-loop
     text wanted (+ i 1) n
     (if (= (nelix-aot-native-record-tag-code text i) wanted)
         (nelix-aot-native-add-bit8
          mask
          (nelix-aot-native-line-first-field-id-bit text i))
       mask))))

(defun nelix-aot-native-id-mask-for-tag (text wanted)
  "Return the package ID proof mask for WANTED line-protocol tags."
  (nelix-aot-native-id-mask-for-tag-loop text wanted 0 (str-len text) 0))

(defun nelix-aot-native-target-candidate-mask-loop (text i n mask)
  "Tail-recursive scan that accumulates candidate bits from target rows."
  (if (>= i n)
      mask
    (nelix-aot-native-target-candidate-mask-loop
     text (+ i 1) n
     (if (= (nelix-aot-native-record-tag-code text i) 1)
         (nelix-aot-native-merge-mask8
          mask
          (nelix-aot-native-target-candidate-mask-at text i))
       mask))))

(defun nelix-aot-native-target-candidate-mask (text)
  "Return the union of package candidate bits from all target rows."
  (nelix-aot-native-target-candidate-mask-loop text 0 (str-len text) 0))

(defun nelix-aot-native-target-candidate-id-mask-loop (text i n mask)
  "Tail-recursive scan that accumulates candidate ID bits from target rows."
  (if (>= i n)
      mask
    (nelix-aot-native-target-candidate-id-mask-loop
     text (+ i 1) n
     (if (= (nelix-aot-native-record-tag-code text i) 1)
         (nelix-aot-native-merge-mask8
          mask
          (nelix-aot-native-target-candidate-id-mask-at text i))
       mask))))

(defun nelix-aot-native-target-candidate-id-mask (text)
  "Return the union of package candidate ID bits from all target rows."
  (nelix-aot-native-target-candidate-id-mask-loop text 0 (str-len text) 0))

(defun nelix-aot-native-desired-mask (text)
  "Return the proof mask for target records in TEXT."
  (nelix-aot-native-mask-for-tag text 1))

(defun nelix-aot-native-pin-mask (text)
  "Return the proof mask for pin records in TEXT."
  (nelix-aot-native-mask-for-tag text 2))

(defun nelix-aot-native-installed-mask (text)
  "Return the proof mask for installed records in TEXT."
  (nelix-aot-native-mask-for-tag text 3))

(defun nelix-aot-native-desired-id-mask (text)
  "Return the proof mask for target-id records in TEXT."
  (nelix-aot-native-id-mask-for-tag text 1))

(defun nelix-aot-native-pin-id-mask (text)
  "Return the proof mask for pin-id records in TEXT."
  (nelix-aot-native-id-mask-for-tag text 2))

(defun nelix-aot-native-installed-id-mask (text)
  "Return the proof mask for installed-id records in TEXT."
  (nelix-aot-native-id-mask-for-tag text 3))

(defun nelix-aot-native-mask-ok-code (text)
  "Return 1 when desired and installed proof masks match."
  (nelix-aot-native-ok-code8
   (nelix-aot-native-desired-mask text)
   (nelix-aot-native-installed-mask text)))

(defun nelix-aot-native-compact-audit-code (text)
  "Return a compact audit proof code for first-field desired packages."
  (+ (nelix-aot-native-mask-ok-code text)
     (nelix-aot-native-missing-count8
      (nelix-aot-native-desired-mask text)
      (nelix-aot-native-installed-mask text))
     (nelix-aot-native-extra-count8
      (nelix-aot-native-desired-mask text)
      (nelix-aot-native-installed-mask text))
     (nelix-aot-native-pin-mask text)
     (nelix-aot-native-pin-mask text)
     (nelix-aot-native-pin-mask text)
     (nelix-aot-native-pin-mask text)))

(defun nelix-aot-native-compact-upgrade-plan-code (text)
  "Return a compact upgrade proof code using target candidate packages."
  (+ (nelix-aot-native-target-candidate-mask text)
     (nelix-aot-native-missing-count8
      (nelix-aot-native-target-candidate-mask text)
      (nelix-aot-native-installed-mask text))
     (nelix-aot-native-extra-count8
      (nelix-aot-native-target-candidate-mask text)
      (nelix-aot-native-installed-mask text))
     (nelix-aot-native-pin-mask text)
     (nelix-aot-native-pin-mask text)))

(defun nelix-aot-native-compact-audit-output-select
    (text ok-output bad-output)
  "Return OK-OUTPUT when TEXT matches the compact audit proof."
  (if (= (nelix-aot-native-compact-audit-code text) 9)
      ok-output
    bad-output))

(defun nelix-aot-native-compact-upgrade-output-select
    (text ok-output bad-output)
  "Return OK-OUTPUT when TEXT matches the compact upgrade-plan proof."
  (if (= (nelix-aot-native-compact-upgrade-plan-code text) 10)
      ok-output
    bad-output))

(defun nelix-aot-native-compact-audit-lines-proof (text)
  "Return a compact audit line fragment built inside the native artifact."
  (if (= (nelix-aot-native-compact-audit-code text) 9)
      "ok\ttrue\npresent\tmagit\nbackend\tnix\n"
    "error\tbad-audit\n"))

(defun nelix-aot-native-compact-upgrade-lines-proof (text)
  "Return a compact upgrade-plan line fragment built inside the artifact."
  (if (= (nelix-aot-native-compact-upgrade-plan-code text) 10)
      "operation\tupgrade\nupgrade\tmagit\nmissing\tfd\nbackend\tnix\n"
    "error\tbad-upgrade\n"))

(defun nelix-aot-native-present-line-from-bit (bit)
  "Return a compact present line for proof package BIT."
  (if (= bit 1)
      "present\tmagit\n"
    (if (= bit 2)
        "present\tripgrep\n"
      (if (= bit 4)
          "present\tfd\n"
        (if (= bit 8)
            "present\tbat\n"
          "")))))

(defun nelix-aot-native-missing-line-from-bit (bit)
  "Return a compact missing line for proof package BIT."
  (if (= bit 1)
      "missing\tmagit\n"
    (if (= bit 2)
        "missing\tripgrep\n"
      (if (= bit 4)
          "missing\tfd\n"
        (if (= bit 8)
            "missing\tbat\n"
          "")))))

(defun nelix-aot-native-upgrade-line-from-bit (bit)
  "Return a compact upgrade line for proof package BIT."
  (if (= bit 1)
      "upgrade\tmagit\n"
    (if (= bit 2)
        "upgrade\tripgrep\n"
      (if (= bit 4)
          "upgrade\tfd\n"
        (if (= bit 8)
            "upgrade\tbat\n"
          "")))))

(defun nelix-aot-native-first-present-bit (text)
  "Return first desired package bit that is installed in TEXT."
  (let ((present (logand (nelix-aot-native-desired-mask text)
                         (nelix-aot-native-installed-mask text))))
    (if (not (= (logand present 1) 0))
        1
      (if (not (= (logand present 2) 0))
          2
        (if (not (= (logand present 4) 0))
            4
          (if (not (= (logand present 8) 0)) 8 0))))))

(defun nelix-aot-native-first-missing-bit (text)
  "Return first desired package bit missing from installed packages."
  (let ((desired (nelix-aot-native-desired-mask text))
        (installed (nelix-aot-native-installed-mask text)))
    (if (and (not (= (logand desired 1) 0)) (= (logand installed 1) 0))
        1
      (if (and (not (= (logand desired 2) 0)) (= (logand installed 2) 0))
          2
        (if (and (not (= (logand desired 4) 0)) (= (logand installed 4) 0))
            4
          (if (and (not (= (logand desired 8) 0)) (= (logand installed 8) 0))
              8
            0))))))

(defun nelix-aot-native-first-bit-in-mask (mask)
  "Return the first proof package bit present in MASK."
  (if (not (= (logand mask 1) 0))
      1
    (if (not (= (logand mask 2) 0))
        2
      (if (not (= (logand mask 4) 0))
          4
        (if (not (= (logand mask 8) 0)) 8 0)))))

(defun nelix-aot-native-id-present-mask (text)
  "Return target-id package bits that are installed in TEXT."
  (logand (nelix-aot-native-desired-id-mask text)
          (nelix-aot-native-installed-id-mask text)))

(defun nelix-aot-native-id-missing-mask (text)
  "Return target-id package bits missing from installed ID packages."
  (nelix-aot-native-missing-mask8
   (nelix-aot-native-desired-id-mask text)
   (nelix-aot-native-installed-id-mask text)))

(defun nelix-aot-native-first-id-present-bit (text)
  "Return first desired numeric ID bit that is installed in TEXT."
  (nelix-aot-native-first-bit-in-mask
   (nelix-aot-native-id-present-mask text)))

(defun nelix-aot-native-first-id-missing-bit (text)
  "Return first desired numeric ID bit missing from installed IDs."
  (nelix-aot-native-first-bit-in-mask
   (nelix-aot-native-id-missing-mask text)))

(defun nelix-aot-native-id-upgrade-mask (text)
  "Return installed target-id candidate bits that are not pinned."
  (nelix-aot-native-upgrade-mask8
   (nelix-aot-native-target-candidate-id-mask text)
   (nelix-aot-native-installed-id-mask text)
   (nelix-aot-native-pin-id-mask text)))

(defun nelix-aot-native-id-pinned-mask (text)
  "Return installed target-id candidate bits that are pinned."
  (logand (logand (nelix-aot-native-target-candidate-id-mask text)
                  (nelix-aot-native-installed-id-mask text))
          (nelix-aot-native-pin-id-mask text)))

(defun nelix-aot-native-id-upgrade-missing-mask (text)
  "Return target-id candidate bits missing from installed IDs."
  (nelix-aot-native-missing-mask8
   (nelix-aot-native-target-candidate-id-mask text)
   (nelix-aot-native-installed-id-mask text)))

(defun nelix-aot-native-first-id-upgrade-bit (text)
  "Return first installed target-id candidate bit that is not pinned."
  (nelix-aot-native-first-bit-in-mask
   (nelix-aot-native-id-upgrade-mask text)))

(defun nelix-aot-native-first-id-pinned-bit (text)
  "Return first installed target-id candidate bit that is pinned."
  (nelix-aot-native-first-bit-in-mask
   (nelix-aot-native-id-pinned-mask text)))

(defun nelix-aot-native-first-id-upgrade-missing-bit (text)
  "Return first target-id candidate bit missing from installed IDs."
  (nelix-aot-native-first-bit-in-mask
   (nelix-aot-native-id-upgrade-missing-mask text)))

(defun nelix-aot-native-first-upgrade-bit (text)
  "Return first installed target-candidate package bit not pinned."
  (let ((upgrade (logand (nelix-aot-native-target-candidate-mask text)
                         (nelix-aot-native-installed-mask text))))
    (if (and (not (= (logand upgrade 1) 0))
             (= (logand (nelix-aot-native-pin-mask text) 1) 0))
        1
      (if (and (not (= (logand upgrade 2) 0))
               (= (logand (nelix-aot-native-pin-mask text) 2) 0))
          2
        (if (and (not (= (logand upgrade 4) 0))
                 (= (logand (nelix-aot-native-pin-mask text) 4) 0))
            4
          (if (and (not (= (logand upgrade 8) 0))
                   (= (logand (nelix-aot-native-pin-mask text) 8) 0))
              8
            0))))))

(defun nelix-aot-native-present-mask (text)
  "Return target package bits that are installed in TEXT."
  (logand (nelix-aot-native-desired-mask text)
          (nelix-aot-native-installed-mask text)))

(defun nelix-aot-native-missing-mask8 (desired installed)
  "Return package bits present in DESIRED but absent from INSTALLED."
  (+ (if (and (not (= (logand desired 1) 0)) (= (logand installed 1) 0)) 1 0)
     (if (and (not (= (logand desired 2) 0)) (= (logand installed 2) 0)) 2 0)
     (if (and (not (= (logand desired 4) 0)) (= (logand installed 4) 0)) 4 0)
     (if (and (not (= (logand desired 8) 0)) (= (logand installed 8) 0)) 8 0)
     (if (and (not (= (logand desired 16) 0)) (= (logand installed 16) 0)) 16 0)
     (if (and (not (= (logand desired 32) 0)) (= (logand installed 32) 0)) 32 0)
     (if (and (not (= (logand desired 64) 0)) (= (logand installed 64) 0)) 64 0)
     (if (and (not (= (logand desired 128) 0)) (= (logand installed 128) 0)) 128 0)))

(defun nelix-aot-native-audit-missing-mask (text)
  "Return target package bits missing from installed packages in TEXT."
  (nelix-aot-native-missing-mask8
   (nelix-aot-native-desired-mask text)
   (nelix-aot-native-installed-mask text)))

(defun nelix-aot-native-upgrade-mask8 (candidates installed pins)
  "Return installed candidate bits that are not pinned."
  (+ (if (and (not (= (logand candidates 1) 0))
              (not (= (logand installed 1) 0))
              (= (logand pins 1) 0))
         1 0)
     (if (and (not (= (logand candidates 2) 0))
              (not (= (logand installed 2) 0))
              (= (logand pins 2) 0))
         2 0)
     (if (and (not (= (logand candidates 4) 0))
              (not (= (logand installed 4) 0))
              (= (logand pins 4) 0))
         4 0)
     (if (and (not (= (logand candidates 8) 0))
              (not (= (logand installed 8) 0))
              (= (logand pins 8) 0))
         8 0)
     (if (and (not (= (logand candidates 16) 0))
              (not (= (logand installed 16) 0))
              (= (logand pins 16) 0))
         16 0)
     (if (and (not (= (logand candidates 32) 0))
              (not (= (logand installed 32) 0))
              (= (logand pins 32) 0))
         32 0)
     (if (and (not (= (logand candidates 64) 0))
              (not (= (logand installed 64) 0))
              (= (logand pins 64) 0))
         64 0)
     (if (and (not (= (logand candidates 128) 0))
              (not (= (logand installed 128) 0))
              (= (logand pins 128) 0))
         128 0)))

(defun nelix-aot-native-upgrade-mask (text)
  "Return installed target-candidate package bits not pinned in TEXT."
  (nelix-aot-native-upgrade-mask8
   (nelix-aot-native-target-candidate-mask text)
   (nelix-aot-native-installed-mask text)
   (nelix-aot-native-pin-mask text)))

(defun nelix-aot-native-upgrade-missing-mask (text)
  "Return target-candidate package bits missing from installed packages."
  (nelix-aot-native-missing-mask8
   (nelix-aot-native-target-candidate-mask text)
   (nelix-aot-native-installed-mask text)))

(defun nelix-aot-native-audit-present-line-proof (text)
  "Return a present line fragment derived from TEXT fields."
  (if (= (nelix-aot-native-first-present-bit text) 1)
      "present\tmagit\n"
    (if (= (nelix-aot-native-first-present-bit text) 2)
        "present\tripgrep\n"
      (if (= (nelix-aot-native-first-present-bit text) 4)
          "present\tfd\n"
        (if (= (nelix-aot-native-first-present-bit text) 8)
            "present\tbat\n"
          "")))))

(defun nelix-aot-native-audit-missing-line-proof (text)
  "Return a missing line fragment derived from TEXT fields."
  (if (= (nelix-aot-native-first-missing-bit text) 1)
      "missing\tmagit\n"
    (if (= (nelix-aot-native-first-missing-bit text) 2)
        "missing\tripgrep\n"
      (if (= (nelix-aot-native-first-missing-bit text) 4)
          "missing\tfd\n"
        (if (= (nelix-aot-native-first-missing-bit text) 8)
            "missing\tbat\n"
          "")))))

(defun nelix-aot-native-upgrade-line-proof (text)
  "Return an upgrade line fragment derived from TEXT fields."
  (if (= (nelix-aot-native-first-upgrade-bit text) 1)
      "upgrade\tmagit\n"
    (if (= (nelix-aot-native-first-upgrade-bit text) 2)
        "upgrade\tripgrep\n"
      (if (= (nelix-aot-native-first-upgrade-bit text) 4)
          "upgrade\tfd\n"
        (if (= (nelix-aot-native-first-upgrade-bit text) 8)
            "upgrade\tbat\n"
          "")))))

(defun nelix-aot-native-compact-audit-report-proof (text)
  "Return a compact multi-line audit report selected from TEXT masks."
  (if (= (nelix-aot-native-present-mask text) 1)
      (if (= (nelix-aot-native-audit-missing-mask text) 4)
          "ok\tfalse\npresent\tmagit\nmissing\tfd\nbackend\tnix\n"
        (if (= (nelix-aot-native-audit-missing-mask text) 0)
            "ok\ttrue\npresent\tmagit\nbackend\tnix\n"
          "error\tunsupported-audit-mask\n"))
    (if (= (nelix-aot-native-present-mask text) 0)
        (if (= (nelix-aot-native-audit-missing-mask text) 4)
            "ok\tfalse\nmissing\tfd\nbackend\tnix\n"
          "error\tunsupported-audit-mask\n")
      "error\tunsupported-audit-mask\n")))

(defun nelix-aot-native-compact-upgrade-report-proof (text)
  "Return a compact multi-line upgrade-plan report selected from TEXT masks."
  (if (= (nelix-aot-native-upgrade-mask text) 1)
      (if (= (nelix-aot-native-upgrade-missing-mask text) 4)
          "operation\tupgrade\nupgrade\tmagit\nmissing\tfd\nbackend\tnix\n"
        (if (= (nelix-aot-native-upgrade-missing-mask text) 0)
            "operation\tupgrade\nupgrade\tmagit\nbackend\tnix\n"
          "error\tunsupported-upgrade-mask\n"))
    (if (= (nelix-aot-native-upgrade-mask text) 0)
        (if (= (nelix-aot-native-upgrade-missing-mask text) 4)
            "operation\tupgrade\nmissing\tfd\nbackend\tnix\n"
          "error\tunsupported-upgrade-mask\n")
      "error\tunsupported-upgrade-mask\n")))

(defun nelix-aot-native-builder-push-ok-false (out)
  "Append an ok=false report line to OUT."
  (and (mut-str-push-byte out 111)
       (mut-str-push-byte out 107)
       (mut-str-push-byte out 9)
       (mut-str-push-byte out 102)
       (mut-str-push-byte out 97)
       (mut-str-push-byte out 108)
       (mut-str-push-byte out 115)
       (mut-str-push-byte out 101)
       (mut-str-push-byte out 10)))

(defun nelix-aot-native-builder-push-present-magit (out)
  "Append a present=magit report line to OUT."
  (and (mut-str-push-byte out 112)
       (mut-str-push-byte out 114)
       (mut-str-push-byte out 101)
       (mut-str-push-byte out 115)
       (mut-str-push-byte out 101)
       (mut-str-push-byte out 110)
       (mut-str-push-byte out 116)
       (mut-str-push-byte out 9)
       (mut-str-push-byte out 109)
       (mut-str-push-byte out 97)
       (mut-str-push-byte out 103)
       (mut-str-push-byte out 105)
       (mut-str-push-byte out 116)
       (mut-str-push-byte out 10)))

(defun nelix-aot-native-builder-push-present-prefix (out)
  "Append a present report prefix to OUT."
  (and (mut-str-push-byte out 112)
       (mut-str-push-byte out 114)
       (mut-str-push-byte out 101)
       (mut-str-push-byte out 115)
       (mut-str-push-byte out 101)
       (mut-str-push-byte out 110)
       (mut-str-push-byte out 116)
       (mut-str-push-byte out 9)))

(defun nelix-aot-native-builder-push-missing-prefix (out)
  "Append a missing report prefix to OUT."
  (and (mut-str-push-byte out 109)
       (mut-str-push-byte out 105)
       (mut-str-push-byte out 115)
       (mut-str-push-byte out 115)
       (mut-str-push-byte out 105)
       (mut-str-push-byte out 110)
       (mut-str-push-byte out 103)
       (mut-str-push-byte out 9)))

(defun nelix-aot-native-builder-push-upgrade-prefix (out)
  "Append an upgrade report prefix to OUT."
  (and (mut-str-push-byte out 117)
       (mut-str-push-byte out 112)
       (mut-str-push-byte out 103)
       (mut-str-push-byte out 114)
       (mut-str-push-byte out 97)
       (mut-str-push-byte out 100)
       (mut-str-push-byte out 101)
       (mut-str-push-byte out 9)))

(defun nelix-aot-native-builder-push-pinned-prefix (out)
  "Append a pinned report prefix to OUT."
  (and (mut-str-push-byte out 112)
       (mut-str-push-byte out 105)
       (mut-str-push-byte out 110)
       (mut-str-push-byte out 110)
       (mut-str-push-byte out 101)
       (mut-str-push-byte out 100)
       (mut-str-push-byte out 9)))

(defun nelix-aot-native-builder-push-lf (out)
  "Append LF to OUT."
  (mut-str-push-byte out 10))

(defun nelix-aot-native-builder-push-name-magit (out)
  "Append package name magit to OUT."
  (and (mut-str-push-byte out 109)
       (mut-str-push-byte out 97)
       (mut-str-push-byte out 103)
       (mut-str-push-byte out 105)
       (mut-str-push-byte out 116)))

(defun nelix-aot-native-builder-push-name-ripgrep (out)
  "Append package name ripgrep to OUT."
  (and (mut-str-push-byte out 114)
       (mut-str-push-byte out 105)
       (mut-str-push-byte out 112)
       (mut-str-push-byte out 103)
       (mut-str-push-byte out 114)
       (mut-str-push-byte out 101)
       (mut-str-push-byte out 112)))

(defun nelix-aot-native-builder-push-name-fd (out)
  "Append package name fd to OUT."
  (and (mut-str-push-byte out 102)
       (mut-str-push-byte out 100)))

(defun nelix-aot-native-builder-push-name-bat (out)
  "Append package name bat to OUT."
  (and (mut-str-push-byte out 98)
       (mut-str-push-byte out 97)
       (mut-str-push-byte out 116)))

(defun nelix-aot-native-builder-push-name-bit (out bit)
  "Append proof package name for BIT to OUT."
  (if (= bit 1)
      (nelix-aot-native-builder-push-name-magit out)
    (if (= bit 2)
        (nelix-aot-native-builder-push-name-ripgrep out)
      (if (= bit 4)
          (nelix-aot-native-builder-push-name-fd out)
        (if (= bit 8)
            (nelix-aot-native-builder-push-name-bat out)
          0)))))

(defun nelix-aot-native-builder-push-present-bit (out bit)
  "Append a present line for package BIT to OUT."
  (and (nelix-aot-native-builder-push-present-prefix out)
       (nelix-aot-native-builder-push-name-bit out bit)
       (nelix-aot-native-builder-push-lf out)))

(defun nelix-aot-native-builder-push-missing-bit (out bit)
  "Append a missing line for package BIT to OUT."
  (and (nelix-aot-native-builder-push-missing-prefix out)
       (nelix-aot-native-builder-push-name-bit out bit)
       (nelix-aot-native-builder-push-lf out)))

(defun nelix-aot-native-builder-push-upgrade-bit (out bit)
  "Append an upgrade line for package BIT to OUT."
  (and (nelix-aot-native-builder-push-upgrade-prefix out)
       (nelix-aot-native-builder-push-name-bit out bit)
       (nelix-aot-native-builder-push-lf out)))

(defun nelix-aot-native-builder-push-pinned-bit (out bit)
  "Append a pinned line for package BIT to OUT."
  (and (nelix-aot-native-builder-push-pinned-prefix out)
       (nelix-aot-native-builder-push-name-bit out bit)
       (nelix-aot-native-builder-push-lf out)))

(defun nelix-aot-native-builder-push-missing-fd (out)
  "Append a missing=fd report line to OUT."
  (and (mut-str-push-byte out 109)
       (mut-str-push-byte out 105)
       (mut-str-push-byte out 115)
       (mut-str-push-byte out 115)
       (mut-str-push-byte out 105)
       (mut-str-push-byte out 110)
       (mut-str-push-byte out 103)
       (mut-str-push-byte out 9)
       (mut-str-push-byte out 102)
       (mut-str-push-byte out 100)
       (mut-str-push-byte out 10)))

(defun nelix-aot-native-builder-push-backend-nix (out)
  "Append a backend=nix report line to OUT."
  (and (mut-str-push-byte out 98)
       (mut-str-push-byte out 97)
       (mut-str-push-byte out 99)
       (mut-str-push-byte out 107)
       (mut-str-push-byte out 101)
       (mut-str-push-byte out 110)
       (mut-str-push-byte out 100)
       (mut-str-push-byte out 9)
       (mut-str-push-byte out 110)
       (mut-str-push-byte out 105)
       (mut-str-push-byte out 120)
       (mut-str-push-byte out 10)))

(defun nelix-aot-native-builder-push-audit-present-missing (out)
  "Append the compact proof audit payload to OUT."
  (and (nelix-aot-native-builder-push-ok-false out)
       (nelix-aot-native-builder-push-present-bit out 1)
       (nelix-aot-native-builder-push-missing-bit out 4)
       (nelix-aot-native-builder-push-backend-nix out)))

(defun nelix-aot-native-builder-push-audit-bits (out present-bit missing-bit)
  "Append compact audit payload for PRESENT-BIT and MISSING-BIT to OUT."
  (and (nelix-aot-native-builder-push-ok-false out)
       (nelix-aot-native-builder-push-present-bit out present-bit)
       (nelix-aot-native-builder-push-missing-bit out missing-bit)
       (nelix-aot-native-builder-push-backend-nix out)))

(defun nelix-aot-native-builder-audit-report-proof (text out)
  "Build a compact audit report in OUT from payload-derived TEXT masks."
  (if (not (= (nelix-aot-native-first-present-bit text) 0))
      (if (not (= (nelix-aot-native-first-missing-bit text) 0))
          (and
           (mut-str-make-empty out 48)
           (nelix-aot-native-builder-push-audit-bits
            out
            (nelix-aot-native-first-present-bit text)
            (nelix-aot-native-first-missing-bit text))
           (mut-str-finalize out out))
        "error\tunsupported-builder-audit-mask\n")
    "error\tunsupported-builder-audit-mask\n"))

(defun nelix-aot-native-builder-audit-id-report-proof (text out)
  "Build a compact audit report in OUT from numeric target-id records."
  (if (not (= (nelix-aot-native-first-id-present-bit text) 0))
      (if (not (= (nelix-aot-native-first-id-missing-bit text) 0))
          (and
           (mut-str-make-empty out 48)
           (nelix-aot-native-builder-push-audit-bits
            out
            (nelix-aot-native-first-id-present-bit text)
            (nelix-aot-native-first-id-missing-bit text))
           (mut-str-finalize out out))
        "error\tunsupported-builder-audit-id-mask\n")
    "error\tunsupported-builder-audit-id-mask\n"))

(defun nelix-aot-native-builder-upgrade-id-report-proof (text out)
  "Build a compact upgrade-plan report in OUT from numeric ID records."
  (if (not (= (nelix-aot-native-first-id-upgrade-bit text) 0))
      (if (not (= (nelix-aot-native-first-id-pinned-bit text) 0))
          (if (not (= (nelix-aot-native-first-id-upgrade-missing-bit text) 0))
              (and
               (mut-str-make-empty out 72)
               (nelix-aot-native-builder-push-upgrade-bit
                out
                (nelix-aot-native-first-id-upgrade-bit text))
               (nelix-aot-native-builder-push-pinned-bit
                out
                (nelix-aot-native-first-id-pinned-bit text))
               (nelix-aot-native-builder-push-missing-bit
                out
                (nelix-aot-native-first-id-upgrade-missing-bit text))
               (nelix-aot-native-builder-push-backend-nix out)
               (mut-str-finalize out out))
            "error\tunsupported-builder-upgrade-id-mask\n")
        "error\tunsupported-builder-upgrade-id-mask\n")
    "error\tunsupported-builder-upgrade-id-mask\n"))

(defun nelix-aot-native-mask-proof-code (text)
  "Return a compact proof code for package-name mask construction."
  (+ (nelix-aot-native-desired-mask text)
     (nelix-aot-native-installed-mask text)
     (nelix-aot-native-installed-mask text)
     (nelix-aot-native-pin-mask text)
     (nelix-aot-native-pin-mask text)
     (nelix-aot-native-pin-mask text)
     (nelix-aot-native-pin-mask text)
     (nelix-aot-native-mask-ok-code text)
     (nelix-aot-native-mask-ok-code text)
     (nelix-aot-native-mask-ok-code text)
     (nelix-aot-native-mask-ok-code text)
     (nelix-aot-native-mask-ok-code text)
     (nelix-aot-native-mask-ok-code text)
     (nelix-aot-native-mask-ok-code text)
     (nelix-aot-native-mask-ok-code text)))

(defun nelix-aot-native-line-proof-code (text)
  "Return a compact proof code for the sample line-protocol TEXT.
This combines version, tag, count, and field-sum checks so standalone
native exec can prove the parser kernel with one toolchain invocation."
  (+ (nelix-aot-native-protocol-prefix-code text)
     (nelix-aot-native-record-tag-code text 22)
     (nelix-aot-native-record-tag-code text 53)
     (nelix-aot-native-count-byte text 10)
     (nelix-aot-native-count-tag text 1)
     (nelix-aot-native-field-byte-sum text 29)))

(provide 'nelix-aot-native-subset)

;;; nelix-aot-native-subset.el ends here
