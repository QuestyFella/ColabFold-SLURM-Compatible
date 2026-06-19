#!/usr/bin/env python3
"""Split a FASTA file into smaller FASTA files for SLURM array jobs."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Split a multi-entry FASTA into one or more FASTA files."
    )
    parser.add_argument("input_fasta", type=Path, help="Input FASTA file")
    parser.add_argument("output_dir", type=Path, help="Directory for split FASTA files")
    parser.add_argument(
        "--records-per-file",
        type=int,
        default=1,
        help="Number of FASTA records per output file (default: 1)",
    )
    parser.add_argument(
        "--list-file",
        type=Path,
        default=None,
        help="Optional file that receives one output FASTA path per line",
    )
    return parser.parse_args()


def sanitize_name(header: str, index: int) -> str:
    name = header[1:].strip().split()[0] if header.startswith(">") else header.strip()
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("._-")
    return name or f"record_{index:04d}"


def read_fasta(path: Path) -> list[tuple[str, list[str]]]:
    records: list[tuple[str, list[str]]] = []
    header: str | None = None
    sequence: list[str] = []

    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            line = raw_line.strip()
            if not line:
                continue
            if line.startswith(">"):
                if header is not None:
                    records.append((header, sequence))
                header = line
                sequence = []
            elif header is None:
                raise ValueError(f"Sequence found before FASTA header at line {line_number}")
            else:
                sequence.append(line)

    if header is not None:
        records.append((header, sequence))

    if not records:
        raise ValueError(f"No FASTA records found in {path}")

    for index, (record_header, record_sequence) in enumerate(records, start=1):
        if not record_sequence:
            raise ValueError(f"Record {index} ({record_header}) has no sequence")

    return records


def write_chunks(
    records: list[tuple[str, list[str]]], output_dir: Path, records_per_file: int
) -> list[Path]:
    if records_per_file < 1:
        raise ValueError("--records-per-file must be at least 1")

    output_dir.mkdir(parents=True, exist_ok=True)
    output_paths: list[Path] = []

    for start in range(0, len(records), records_per_file):
        chunk = records[start : start + records_per_file]
        first_header = chunk[0][0]
        chunk_number = start // records_per_file + 1
        basename = sanitize_name(first_header, chunk_number)
        if records_per_file > 1:
            basename = f"batch_{chunk_number:04d}_{basename}"

        output_path = output_dir / f"{chunk_number:04d}_{basename}.fasta"
        with output_path.open("w", encoding="utf-8") as handle:
            for header, sequence in chunk:
                handle.write(f"{header}\n")
                handle.write("\n".join(sequence))
                handle.write("\n")
        output_paths.append(output_path.resolve())

    return output_paths


def main() -> int:
    args = parse_args()
    records = read_fasta(args.input_fasta)
    output_paths = write_chunks(records, args.output_dir, args.records_per_file)

    list_file = args.list_file
    if list_file is not None:
        list_file.parent.mkdir(parents=True, exist_ok=True)
        list_file.write_text(
            "".join(f"{path}\n" for path in output_paths), encoding="utf-8"
        )

    print(f"Wrote {len(output_paths)} FASTA file(s) from {len(records)} record(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
