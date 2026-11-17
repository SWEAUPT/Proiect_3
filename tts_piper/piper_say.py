"""Sintetizeaza un text romanesc cu Piper, offline.

Folosit de speak_forecast.m (Client 'piper'):
    python piper_say.py <model.onnx> <text_utf8.txt> <iesire.wav>

Textul se citeste dintr-un fisier UTF-8, nu din linia de comanda: pe Windows
argumentele si stdin trec prin pagina de cod a consolei, iar diacriticele
(ă â î ș ț) s-ar pierde - exact ce face pronuntia romaneasca sa sune corect.
"""
import sys
import wave

from piper import PiperVoice


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    model, text_file, out_wav = sys.argv[1:]
    with open(text_file, encoding="utf-8") as f:
        text = f.read().strip()
    if not text:
        print("text gol", file=sys.stderr)
        return 3
    voice = PiperVoice.load(model)
    with wave.open(out_wav, "wb") as wf:
        voice.synthesize_wav(text, wf)
    return 0


if __name__ == "__main__":
    sys.exit(main())
