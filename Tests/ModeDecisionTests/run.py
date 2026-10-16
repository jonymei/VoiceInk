import argparse
import os
from pathlib import Path
import subprocess


parser = argparse.ArgumentParser()
parser.add_argument("--build-dir", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
state = repo / "VoiceInk/Features/Modes/State"
models = repo / "VoiceInk/Features/Modes/Models"

# Compile the real configuration/draft/resolver without the unrelated application manager.
config = (state / "ModeConfig.swift").read_text()
assert config.count("enum ModeRemovalResult {") == 1
sources = [
    "import Foundation\n@testable import DoubaoClient\n@testable import EnhancementPolicy\n",
    config.split("enum ModeRemovalResult {", 1)[0],
    (models / "ModeIcon.swift").read_text(),
    (models / "ModeTriggerModels.swift").read_text(),
    (state / "ModeConfigDraft.swift").read_text(),
    (state / "ModeRuntimeConfiguration.swift").read_text(),
    (Path(__file__).with_name("Support.swift")).read_text(),
    (Path(__file__).with_name("Checks.swift")).read_text(),
]
transport = (repo / "Tests/DoubaoClientTests/ParallelPolishEndToEndTests.swift").read_text()
sources.append(transport[transport.index("private final class LoopbackDecisionProtocol:"):])
harness = output / "Harness.swift"
harness.write_text("\n".join(sources))
objects = [
    str(obj)
    for target in ("DoubaoClient", "EnhancementPolicy")
    for obj in sorted((args.build_dir / f"{target}.build").glob("*.swift.o"))
]
assert objects, "Run swift test to build the client modules first"
binary = output / "mode-decision-checks"
subprocess.run(
    ["swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(args.build_dir / "Modules"),
     str(harness), *objects, "-lz", "-o", str(binary)],
    check=True, timeout=90,
)
env = os.environ.copy()
env["CFFIXED_USER_HOME"] = str(output / "test-home")
Path(env["CFFIXED_USER_HOME"]).mkdir()
fixture = repo / "Tests/DoubaoClientTests/Fixtures/parallel_polish_server.py"
subprocess.run([str(binary), str(fixture), str(output)], check=True, timeout=30, env=env)
