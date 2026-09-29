#!/usr/bin/env python3
"""IVY local inference engine.

A small sidecar that hosts one MLX model per process and speaks JSON Lines over
stdin/stdout. The Swift app (see EngineProcess.swift) starts it on demand, so the
user never has to start a server manually. Everything runs locally on Apple Silicon.

Roles
-----
  --role llm      MLX-LM chat model (default: Qwen3-4B-4bit) with tool calling
  --role stt      MLX Whisper speech-to-text
  --role tts      Kokoro-82M text-to-speech via mlx-audio
  --role doctor   Print runtime diagnostics as one JSON object and exit
  --role download --repo <hf repo> --dest <dir>   Download a model (setup only)

Protocol
--------
Requests:  {"id": "...", "op": "load" | "generate" | "transcribe" | "synthesize" | "cancel" | "ping" | "shutdown", ...}
Responses: {"id": "...", "event": "ready" | "token" | "chunk" | "progress" | "done" | "error", ...}

Only the protocol is written to the real stdout. Anything libraries print is
redirected to stderr, which the Swift side forwards to os.Logger.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import sys
import threading
import time
import traceback
import wave

# --- stdout hygiene ---------------------------------------------------------
# Keep a private handle to the real stdout for the protocol, then point fd 1 at
# stderr so stray prints from ML libraries can never corrupt the JSON stream.
_PROTO = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
os.dup2(2, 1)
sys.stdout = sys.stderr
_EMIT_LOCK = threading.Lock()


def emit(obj: dict) -> None:
    line = json.dumps(obj, ensure_ascii=False)
    with _EMIT_LOCK:
        _PROTO.write(line + "\n")
        _PROTO.flush()


def log(message: str) -> None:
    print(f"[ivy-engine] {message}", file=sys.stderr, flush=True)


class Cancelled(Exception):
    pass


# --- Roles ------------------------------------------------------------------


class Role:
    def __init__(self) -> None:
        self.cancelled: set[str] = set()

    def check_cancel(self, request_id: str) -> None:
        if request_id in self.cancelled:
            self.cancelled.discard(request_id)
            raise Cancelled()

    def handle(self, request: dict) -> None:  # pragma: no cover - overridden
        raise NotImplementedError


class LLMRole(Role):
    """MLX-LM chat generation with prompt-prefix KV cache reuse.

    The system prompt and tool schemas are identical between requests, so the KV
    cache for that prefix is kept and only the new suffix is prefilled. This keeps
    first-token latency low on a MacBook Air, including the second pass after a
    tool call.
    """

    def __init__(self) -> None:
        super().__init__()
        self.model = None
        self.tokenizer = None
        self.model_path = None
        self.cache = None
        self.cache_tokens: list[int] = []

    def load(self, request: dict) -> None:
        from mlx_lm import load

        path = request["model_path"]
        if self.model is not None and self.model_path == path:
            emit({"id": request["id"], "event": "done", "loaded": path})
            return
        started = time.time()
        self.model, self.tokenizer = load(path)
        self.model_path = path
        self.reset_cache()
        emit({"id": request["id"], "event": "done", "loaded": path, "seconds": round(time.time() - started, 2)})

    def reset_cache(self) -> None:
        from mlx_lm.models.cache import make_prompt_cache

        self.cache = make_prompt_cache(self.model)
        self.cache_tokens = []

    def cache_offset(self) -> int:
        try:
            return int(self.cache[0].offset)
        except Exception:
            return 0

    def encode(self, messages, tools) -> list[int]:
        kwargs = {"add_generation_prompt": True, "tokenize": False}
        if tools:
            kwargs["tools"] = tools
        try:
            # Qwen3: disable the <think> phase; IVY wants short, immediate answers.
            text = self.tokenizer.apply_chat_template(messages, enable_thinking=False, **kwargs)
        except TypeError:
            text = self.tokenizer.apply_chat_template(messages, **kwargs)
        return list(self.tokenizer.encode(text, add_special_tokens=False))

    def generate(self, request: dict) -> None:
        from mlx_lm import stream_generate
        from mlx_lm.models.cache import can_trim_prompt_cache, trim_prompt_cache
        from mlx_lm.sample_utils import make_sampler

        if self.model is None:
            raise RuntimeError("model not loaded")
        rid = request["id"]
        tokens = self.encode(request["messages"], request.get("tools"))
        context_length = int(request.get("context_length", 8192))
        if len(tokens) > context_length:
            raise RuntimeError(f"prompt is {len(tokens)} tokens; context length is {context_length}")

        # Longest common prefix with what is already in the KV cache.
        common = 0
        limit = min(len(self.cache_tokens), len(tokens) - 1)
        while common < limit and self.cache_tokens[common] == tokens[common]:
            common += 1
        if common < len(self.cache_tokens):
            if can_trim_prompt_cache(self.cache):
                trim_prompt_cache(self.cache, len(self.cache_tokens) - common)
            else:
                self.reset_cache()
                common = 0
        self.cache_tokens = tokens[:common]

        sampler = make_sampler(temp=float(request.get("temperature", 0.3)), top_p=float(request.get("top_p", 0.9)))
        max_tokens = int(request.get("max_tokens", 320))
        started = time.time()
        first_token_at = None
        pieces: list[str] = []
        generated: list[int] = []
        finish = "stop"
        try:
            for response in stream_generate(
                self.model,
                self.tokenizer,
                prompt=tokens[common:],
                max_tokens=max_tokens,
                sampler=sampler,
                prompt_cache=self.cache,
            ):
                if first_token_at is None:
                    first_token_at = time.time()
                generated.append(int(response.token))
                if response.text:
                    pieces.append(response.text)
                    emit({"id": rid, "event": "token", "text": response.text})
                if response.finish_reason:
                    finish = response.finish_reason
                if rid in self.cancelled:
                    finish = "cancelled"
                    break
        finally:
            # Record exactly what the cache now contains so the next request can reuse it.
            offset = self.cache_offset()
            self.cache_tokens = (tokens + generated)[:offset]

        self.cancelled.discard(rid)
        elapsed = time.time() - started
        emit(
            {
                "id": rid,
                "event": "done",
                "text": "".join(pieces),
                "finish_reason": finish,
                "prompt_tokens": len(tokens),
                "cached_tokens": common,
                "generation_tokens": len(generated),
                "first_token_seconds": round((first_token_at or time.time()) - started, 3),
                "seconds": round(elapsed, 3),
            }
        )

    def handle(self, request: dict) -> None:
        op = request.get("op")
        if op == "load":
            self.load(request)
        elif op == "generate":
            self.generate(request)
        elif op == "reset":
            if self.model is not None:
                self.reset_cache()
            emit({"id": request["id"], "event": "done"})
        else:
            raise RuntimeError(f"unsupported op {op}")


class STTRole(Role):
    """MLX Whisper transcription of raw 16 kHz mono float32 PCM written by the app."""

    SAMPLE_RATE = 16000

    def __init__(self) -> None:
        super().__init__()
        self.model_path = None

    def load(self, request: dict) -> None:
        import numpy as np
        import mlx_whisper

        self.model_path = request["model_path"]
        started = time.time()
        # Warm up: loads and compiles the weights so the first real request is fast.
        mlx_whisper.transcribe(np.zeros(self.SAMPLE_RATE, dtype=np.float32), path_or_hf_repo=self.model_path,
                               language="en", verbose=None)
        emit({"id": request["id"], "event": "done", "loaded": self.model_path,
              "seconds": round(time.time() - started, 2)})

    def transcribe(self, request: dict) -> None:
        import numpy as np
        import mlx_whisper

        if self.model_path is None:
            raise RuntimeError("model not loaded")
        audio = np.fromfile(request["pcm_path"], dtype=np.float32)
        duration = len(audio) / self.SAMPLE_RATE
        rms = float(np.sqrt(np.mean(np.square(audio)))) if len(audio) else 0.0
        # Whisper hallucinates ("Thank you.") on silence; skip near-silent clips.
        if duration < 0.3 or rms < 0.002:
            emit({"id": request["id"], "event": "done", "text": "", "duration": round(duration, 2), "silent": True})
            return
        language = request.get("language") or None
        if language == "auto":
            language = None
        started = time.time()
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self.model_path,
            language=language,
            verbose=None,
            condition_on_previous_text=False,
            temperature=(0.0, 0.2, 0.4),
            no_speech_threshold=0.6,
            hallucination_silence_threshold=2.0,
            word_timestamps=False,
        )
        text = (result.get("text") or "").strip()
        emit({"id": request["id"], "event": "done", "text": text, "language": result.get("language"),
              "duration": round(duration, 2), "seconds": round(time.time() - started, 3)})

    def handle(self, request: dict) -> None:
        op = request.get("op")
        if op == "load":
            self.load(request)
        elif op == "transcribe":
            self.transcribe(request)
        else:
            raise RuntimeError(f"unsupported op {op}")


class TTSRole(Role):
    """Kokoro-82M via mlx-audio. Streams one WAV file per sentence for low latency."""

    def __init__(self) -> None:
        super().__init__()
        self.model = None
        self.model_path = None

    def load(self, request: dict) -> None:
        from pathlib import Path
        from mlx_audio.tts.utils import load_model

        path = request["model_path"]
        started = time.time()
        if self.model is None or self.model_path != path:
            self.model = load_model(Path(path))
            self.model_path = path
            # Warm up the G2P pipeline and the vocoder.
            for _ in self.model.generate(text="Ready.", voice=self.voice_path("af_heart"), speed=1.0, lang_code="a"):
                pass
        emit({"id": request["id"], "event": "done", "loaded": path, "seconds": round(time.time() - started, 2)})

    def voice_path(self, voice: str) -> str:
        candidate = os.path.join(self.model_path or "", "voices", f"{voice}.safetensors")
        return candidate if os.path.exists(candidate) else voice

    def synthesize(self, request: dict) -> None:
        import numpy as np

        if self.model is None:
            raise RuntimeError("model not loaded")
        rid = request["id"]
        text = request["text"].strip()
        voice = request.get("voice") or "af_heart"
        speed = float(request.get("speed", 1.0))
        out_dir = request["out_dir"]
        os.makedirs(out_dir, exist_ok=True)
        lang_code = voice[0] if voice and voice[0] in "abefhijpz" else "a"
        index = 0
        for result in self.model.generate(
            text=text,
            voice=self.voice_path(voice),
            speed=speed,
            lang_code=lang_code,
            split_pattern=r"(?<=[.!?])\s+|\n+",
        ):
            self.check_cancel(rid)
            audio = np.array(result.audio, dtype=np.float32).reshape(-1)
            path = os.path.join(out_dir, f"{rid}-{index:03d}.wav")
            write_wav(path, audio, int(result.sample_rate))
            emit({"id": rid, "event": "chunk", "path": path, "index": index,
                  "seconds": round(len(audio) / float(result.sample_rate), 3)})
            index += 1
        emit({"id": rid, "event": "done", "chunks": index})

    def handle(self, request: dict) -> None:
        op = request.get("op")
        if op == "load":
            self.load(request)
        elif op == "synthesize":
            self.synthesize(request)
        else:
            raise RuntimeError(f"unsupported op {op}")


def write_wav(path: str, audio, sample_rate: int) -> None:
    import numpy as np

    clipped = np.clip(audio, -1.0, 1.0)
    pcm = (clipped * 32767.0).astype("<i2")
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(pcm.tobytes())


# --- One-shot roles -----------------------------------------------------------


def run_doctor() -> int:
    import importlib
    import platform

    report = {"python": platform.python_version(), "machine": platform.machine(), "packages": {}}
    for name in ["mlx", "mlx_lm", "mlx_whisper", "mlx_audio", "misaki", "numpy", "huggingface_hub", "spacy"]:
        try:
            module = importlib.import_module(name)
            report["packages"][name] = getattr(module, "__version__", "installed")
        except Exception as exc:  # noqa: BLE001
            report["packages"][name] = None
            report.setdefault("errors", {})[name] = str(exc)
    try:
        import spacy.util

        report["spacy_en_core_web_sm"] = spacy.util.is_package("en_core_web_sm")
    except Exception:  # noqa: BLE001
        report["spacy_en_core_web_sm"] = False
    emit({"event": "done", "report": report})
    return 0


def directory_size(path: str) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return total


def run_download(repo: str, dest: str, allow: list[str] | None) -> int:
    # Downloads are the only network access the engine ever performs, and only when
    # the user explicitly installs a model from IVY's setup/settings.
    os.environ.pop("HF_HUB_OFFLINE", None)
    from huggingface_hub import HfApi, snapshot_download

    total = 0
    try:
        info = HfApi().model_info(repo, files_metadata=True)
        import fnmatch

        for sibling in info.siblings or []:
            if allow and not any(fnmatch.fnmatch(sibling.rfilename, pattern) for pattern in allow):
                continue
            total += int(sibling.size or 0)
    except Exception as exc:  # noqa: BLE001
        log(f"could not read model size: {exc}")

    done = threading.Event()

    def report() -> None:
        while not done.wait(0.5):
            emit({"event": "progress", "bytes": directory_size(dest), "total": total})

    threading.Thread(target=report, daemon=True).start()
    try:
        snapshot_download(repo_id=repo, local_dir=dest, allow_patterns=allow or None)
    except Exception as exc:  # noqa: BLE001
        done.set()
        emit({"event": "error", "message": str(exc)})
        return 1
    done.set()
    emit({"event": "done", "bytes": directory_size(dest), "total": total, "path": dest})
    return 0


# --- Main loop ----------------------------------------------------------------


def serve(role: Role) -> int:
    work: "queue.Queue[dict | None]" = queue.Queue()

    def worker() -> None:
        while True:
            request = work.get()
            if request is None:
                return
            rid = request.get("id", "")
            try:
                role.handle(request)
            except Cancelled:
                emit({"id": rid, "event": "done", "cancelled": True})
            except Exception as exc:  # noqa: BLE001
                log(traceback.format_exc())
                emit({"id": rid, "event": "error", "message": str(exc)})

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    emit({"event": "ready", "pid": os.getpid()})

    # Block on stdin: zero CPU while idle. EOF means the app went away.
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            emit({"event": "error", "message": "invalid JSON"})
            continue
        op = request.get("op")
        if op == "cancel":
            role.cancelled.add(request.get("target", ""))
            continue
        if op == "ping":
            emit({"id": request.get("id"), "event": "done", "pong": True})
            continue
        if op == "shutdown":
            break
        work.put(request)

    work.put(None)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="IVY local MLX engine")
    parser.add_argument("--role", required=True, choices=["llm", "stt", "tts", "doctor", "download"])
    parser.add_argument("--repo")
    parser.add_argument("--dest")
    parser.add_argument("--allow", action="append")
    args = parser.parse_args()

    if args.role == "doctor":
        return run_doctor()
    if args.role == "download":
        if not args.repo or not args.dest:
            parser.error("--repo and --dest are required for download")
        return run_download(args.repo, args.dest, args.allow)

    roles = {"llm": LLMRole, "stt": STTRole, "tts": TTSRole}
    return serve(roles[args.role]())


if __name__ == "__main__":
    sys.exit(main())
