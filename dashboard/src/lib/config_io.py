import os
import re
from dataclasses import dataclass
from typing import List, Optional

@dataclass
class DomainEntry:
    raw_line: str
    domain: str
    is_commented: bool
    is_block_header: bool = False
    is_section_header: bool = False
    block_tag: Optional[str] = None

class ConfigIO:
    def __init__(self, repo_root: str):
        self.repo_root = repo_root
        self.allowed_domains_path = os.path.join(repo_root, "proxy", "allowed_domains.txt")

    def read_allowed_domains(self) -> List[DomainEntry]:
        if not os.path.exists(self.allowed_domains_path):
            return []

        entries = []
        with open(self.allowed_domains_path, "r") as f:
            lines = f.readlines()

        current_block_tag = None
        for line in lines:
            stripped = line.strip()
            
            # Section header check: === NAME ===
            if stripped.startswith("# ===") and stripped.endswith("==="):
                entries.append(DomainEntry(raw_line=line, domain="", is_commented=False, is_section_header=True))
                continue

            # Block header check: # --- Name [tag] ---
            match = re.search(r'# --- .* \[(.*)\] ---', stripped)
            if match:
                current_block_tag = match.group(1)
                entries.append(DomainEntry(raw_line=line, domain="", is_commented=False, is_block_header=True, block_tag=current_block_tag))
                continue

            # Domain check
            # A domain line is either "domain.com" or "# domain.com"
            # It should NOT be a long comment line or section separator
            
            is_commented = stripped.startswith("#")
            content_after_hash = stripped[1:].strip() if is_commented else stripped
            
            # Hostname regex: starts with a letter, number, or dot (for wildcards), 
            # contains only letters, numbers, dots, hyphens.
            is_likely_domain = False
            if content_after_hash and not any(c.isspace() for c in content_after_hash):
                if "." in content_after_hash and re.match(r'^[a-zA-Z0-9\.-]+$', content_after_hash):
                    is_likely_domain = True

            if is_likely_domain:
                entries.append(DomainEntry(
                    raw_line=line, 
                    domain=content_after_hash, 
                    is_commented=is_commented, 
                    block_tag=current_block_tag
                ))
            else:
                # It's a regular comment or blank line
                entries.append(DomainEntry(raw_line=line, domain="", is_commented=is_commented))

        return entries

    def write_allowed_domains(self, entries: List[DomainEntry]):
        with open(self.allowed_domains_path, "w") as f:
            for entry in entries:
                if entry.domain:
                    # Reconstruct domain line
                    prefix = "# " if entry.is_commented else ""
                    f.write(f"{prefix}{entry.domain}\n")
                else:
                    f.write(entry.raw_line)

    def toggle_block(self, tag: str, enable: bool):
        entries = self.read_allowed_domains()
        for entry in entries:
            if entry.block_tag == tag and entry.domain:
                entry.is_commented = not enable
        self.write_allowed_domains(entries)

    def add_domain(self, domain: str, block_tag: Optional[str] = None):
        entries = self.read_allowed_domains()

        # Inherit comment state from the last existing domain in the block.
        # Otherwise adding a host to e.g. the [pypi] block (commented by
        # default for autonomous-mode safety) would silently open egress.
        new_is_commented = False
        if block_tag:
            block_domains = [e for e in entries if e.block_tag == block_tag and e.domain]
            if block_domains:
                new_is_commented = block_domains[-1].is_commented

        new_entry = DomainEntry(
            raw_line=f"{domain}\n",
            domain=domain,
            is_commented=new_is_commented,
            block_tag=block_tag,
        )

        if block_tag:
            # Find the end of the block and insert there
            last_idx = -1
            for i, entry in enumerate(entries):
                if entry.block_tag == block_tag:
                    last_idx = i

            if last_idx != -1:
                entries.insert(last_idx + 1, new_entry)
            else:
                entries.append(new_entry)
        else:
            entries.append(new_entry)

        self.write_allowed_domains(entries)
