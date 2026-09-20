(in-package #:nyaa)

;;; Ollama, through the OpenAI-compatible API it serves alongside its native
;;; one. No key, so it is the provider a development machine can run end to
;;; end.
;;;
;;; The /v1 endpoint drops the native one's usage counters (eval_count,
;;; total_duration) and its options (num_ctx, format, keep_alive); whatever
;;; /v1 does return lands in :meta. A native Ollama protocol is tracked in
;;; ~takeiteasy/nyaa#38.

(define-provider :ollama
  :protocol :protocol-openai
  :base-url "http://127.0.0.1:11434/v1"
  :auth :none
  ;; Advertisement, not a gate: the real catalogue is whatever has been
  ;; pulled, which only the running backend knows.
  :models '("llama3.2" "qwen2.5-coder" "gemma3")
  :summary "Local Ollama, OpenAI-compatible endpoint")
