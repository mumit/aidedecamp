"""``python -m aidedecamp`` — start the always-on process (design doc 4.6).

Deliberately thin: all the wiring logic lives in ``runtime.py`` and is
independently tested there. This file just calls it.
"""

from .runtime import build_runtime

if __name__ == "__main__":  # pragma: no cover - requires live services
    build_runtime().run()
