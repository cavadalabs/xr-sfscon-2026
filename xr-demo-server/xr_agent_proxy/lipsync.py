"""Optional NoiBot cues from the exact output audio; analysis stays on the server."""
import asyncio
import io
import json
import logging
import math
from pathlib import Path
import shutil
import tempfile
import wave

logger = logging.getLogger("uvicorn.error")


async def mouth_cues(audio: bytes, sample_rate: int, settings) -> list[dict]:
    package = settings.lipsync_package
    node = shutil.which("node")
    if not package or not node or not audio or len(audio) > 16 * 1024 * 1024:
        return []
    try:
        if not audio.startswith(b"RIFF"):
            if not 8000 <= sample_rate <= 96000 or len(audio) % 2:
                return []
            output = io.BytesIO()
            with wave.open(output, "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(sample_rate)
                wav.writeframes(audio)
            audio = output.getvalue()
        with wave.open(io.BytesIO(audio)) as wav:
            duration = wav.getnframes() / wav.getframerate()
        if not 0 < duration <= 90:
            return []
        with tempfile.TemporaryDirectory(prefix="noi-noibot-cues-") as directory:
            source, destination = Path(directory) / "speech.wav", Path(directory) / "cues.json"
            source.write_bytes(audio)
            process = await asyncio.create_subprocess_exec(
                node, str(Path(__file__).parents[1] / "tools/noibot_lipsync.mjs"),
                package, str(source), str(destination),
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
            )
            try:
                await asyncio.wait_for(process.wait(), settings.lipsync_timeout_seconds)
                if process.returncode:
                    return []
                cues = json.loads(destination.read_text())["mouthCues"]
                previous_end = 0.0
                if not isinstance(cues, list) or len(cues) > 20000:
                    return []
                for cue in cues:
                    start, end = cue["start"], cue["end"]
                    if (type(start) not in (int, float) or type(end) not in (int, float)
                            or not math.isfinite(start) or not math.isfinite(end)
                            or start < previous_end - 0.001 or end <= start
                            or end > duration + 0.1 or cue["value"] not in "ABCDEFGHX"
                            or len(cue["value"]) != 1):
                        return []
                    previous_end = end
                return cues
            finally:
                if process.returncode is None:
                    process.kill()
                    await process.wait()
    except (OSError, ValueError, KeyError, TypeError, wave.Error, asyncio.TimeoutError):
        logger.warning("NoiBot lip analysis unavailable; audio playback remains enabled")
        return []
