#!/usr/bin/env python3
"""Pull <ValidationCode> blocks out of an Evaluate-STIG answer file.

Writing the snippet to a .ps1 file first is what makes it testable: it parse-checks
with [Parser]::ParseFile and runs under test-validationcode.ps1. It also proves the
XML escaping survived - what comes out here is exactly what Evaluate-STIG splices
into its wrapper.

    python3 -I extract-validationcode.py answerfile.xml              # list all
    python3 -I extract-validationcode.py answerfile.xml V-251550     # one Vuln
    python3 -I extract-validationcode.py answerfile.xml V-251550 1   # one Index
"""
import sys
import xml.etree.ElementTree as ET


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    path = sys.argv[1]
    want_vuln = sys.argv[2] if len(sys.argv) > 2 else None
    want_index = sys.argv[3] if len(sys.argv) > 3 else None

    root = ET.parse(path).getroot()
    found = 0

    for vuln in root.iter("Vuln"):
        vuln_id = vuln.get("ID", "")
        if want_vuln and vuln_id != want_vuln:
            continue
        for key in vuln.iter("AnswerKey"):
            key_name = key.get("Name", "")
            for answer in key.iter("Answer"):
                index = answer.get("Index", "")
                if want_index and index != want_index:
                    continue
                node = answer.find("ValidationCode")
                code = (node.text or "").strip() if node is not None else ""
                found += 1
                # Header to stderr so stdout is pipeable straight into a .ps1 file.
                print(
                    f"# {vuln_id} key={key_name!r} index={index} "
                    f"expected={answer.get('ExpectedStatus', '')!r} "
                    f"{'(empty - true is assumed)' if not code else ''}",
                    file=sys.stderr,
                )
                if code:
                    print(code)

    if not found:
        print("no matching <Answer> found", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
