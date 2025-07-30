#! /usr/bin/env nix-shell
#! nix-shell -i python3 -p nix python3 nix-search-tv python3Packages.deepdiff git

import json
import logging
import os
import re
import signal
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from queue import Queue, Empty
from typing import Any

from deepdiff import DeepDiff

# --- Configuration ---
PKGS_ROOT = Path(".")
MAX_FILE_SIZE_BYTES = 100 * 1024
PROCESSED_FILE = PKGS_ROOT / ".meta_remover_processed.json"
SKIPPED_FILE = PKGS_ROOT / ".meta_remover_skipped.json"
FAILED_FILE = PKGS_ROOT / ".meta_remover_failed_paths.json"
LOG_FILE = PKGS_ROOT / "meta_remover.log"
IGNORE_KEYS_IN_META = {"position", "maintainersPosition", "metaPosition", "teamsPosition"}
SAVE_PROGRESS_INTERVAL_S = 60
MAX_WORKERS = 16
COMMAND_TIMEOUT_S = 120
EXCLUDED_PACKAGE_SETS = {
    "haskellPackages", "androidenv", "gnomeExtensions", "emacsPackages",
    "chickenPackages", "sbclPackages", "vimPlugins", "rubyPackages",
    "perl540Packages", "perl538Packages", "lua52Packages", "python313Packages"
}

# --- Logging Setup ---
class ConsoleLogFilter(logging.Filter):
    def filter(self, record):
        if record.levelno >= logging.ERROR: return True
        if record.levelno == logging.INFO: return "skipping" not in record.getMessage()
        return False

logger = logging.getLogger()
logger.setLevel(logging.INFO)
if logger.hasHandlers(): logger.handlers.clear()
formatter = logging.Formatter('[%(asctime)s] [%(levelname)s] [%(threadName)s] %(message)s', datefmt='%H:%M:%S')
console_handler = logging.StreamHandler()
console_handler.setLevel(logging.INFO)
console_handler.addFilter(ConsoleLogFilter())
console_handler.setFormatter(formatter)
logger.addHandler(console_handler)
file_handler = logging.FileHandler(LOG_FILE, mode="a", encoding="utf-8")
file_handler.setLevel(logging.INFO)
file_handler.setFormatter(formatter)
logger.addHandler(file_handler)

# --- Global State for Graceful Shutdown & Reliability ---
stop_event = threading.Event()
in_flight_tasks: dict[str, Path] = {}
in_flight_lock = threading.Lock()
master_lock = threading.Lock()
# RELIABILITY: A lock to serialize ONLY git write/restore operations.
git_lock = threading.Lock()
failed_files_lock = threading.Lock()
failed_files_during_run: set[Path] = set()

@dataclass
class ProcessingTask:
    pkg_name: str
    attr_path: str
    source_path: Path

# --- Core Functions ---

def run_command(cmd: list[str], timeout: int, cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            cmd, check=check, capture_output=True, text=True, encoding="utf-8",
            timeout=timeout, cwd=cwd or PKGS_ROOT
        )
    except subprocess.CalledProcessError as e:
        error_details = (f"Command '{' '.join(e.cmd)}' failed with exit code {e.returncode}.\n"
                       f"--- Stderr ---\n{e.stderr or 'No stderr output.'}\n"
                       f"--- Stdout ---\n{e.stdout or 'No stdout output.'}")
        e.add_note(error_details)
        raise e
    except subprocess.TimeoutExpired as e:
        timeout_details = f"Command '{' '.join(cmd)}' timed out after {timeout} seconds."
        e.add_note(timeout_details)
        raise e

def list_all_package_names() -> list[str]:
    logging.info("Fetching all package names...")
    try:
        result = run_command(['nix-search-tv', 'print'], timeout=COMMAND_TIMEOUT_S)
        lines = result.stdout.strip().splitlines()
        packages = [line for line in lines if line.startswith('nixpkgs/') and line.count('/') == 1]
        logging.info(f"Found {len(packages)} potential packages.")
        return packages
    except Exception as e:
        logging.critical(f"Fatal: Failed to list packages. Exiting. Error: {e}")
        return []

def find_matching_brace(text: str, start_index: int) -> int:
    if text[start_index] != '{': return -1
    brace_level = 1
    for i in range(start_index + 1, len(text)):
        char = text[i]
        if char == '{': brace_level += 1
        elif char == '}':
            brace_level -= 1
            if brace_level == 0: return i
    return -1

def produce_tasks(all_pkgs: list[str], already_handled: set[str], task_queue: Queue, skipped_list: set[str]):
    total = len(all_pkgs)
    logging.info("Producer starting: scanning for tasks...")
    for i, pkg_name in enumerate(all_pkgs):
        if stop_event.is_set(): break
        if (i + 1) % 500 == 0: logging.info(f"Producer progress [{i+1}/{total}]...")
        if pkg_name in already_handled: continue

        try:
            if any(keyword in pkg_name for keyword in EXCLUDED_PACKAGE_SETS):
                with master_lock: skipped_list.add(pkg_name)
                continue

            attr_path = pkg_name.split('/', 1)[1].strip()
            
            try:
                source_result = run_command(['nix-search-tv', 'source', pkg_name], timeout=COMMAND_TIMEOUT_S)
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                logging.warning(f"'{pkg_name}': Failed to get source, skipping for this run.")
                continue

            url = source_result.stdout.strip()
            match = re.search(r'/nixpkgs/blob/[^/]+/(pkgs/.+\.nix|lib/.+\.nix)$', url)
            if not match:
                logging.warning(f"'{pkg_name}': Could not parse source URL: {url}. Will retry.")
                continue
            
            source_path = PKGS_ROOT / match.group(1)
            if source_path.suffix != '.nix' or 'generated' in str(source_path):
                logging.info(f"'{pkg_name}': Path {source_path} is unsuitable, permanently skipping.")
                with master_lock: skipped_list.add(pkg_name)
                continue

            if not source_path.exists():
                logging.warning(f"'{pkg_name}': File {source_path} does not exist. Will retry.")
                continue

            if source_path.stat().st_size > MAX_FILE_SIZE_BYTES:
                logging.warning(f"'{pkg_name}': File {source_path} is too large, permanently skipping.")
                with master_lock: skipped_list.add(pkg_name)
                continue
            
            content = source_path.read_text('utf-8')
            meta_with_lib_str = 'meta = with lib;'
            if meta_with_lib_str not in content:
                with master_lock: skipped_list.add(pkg_name)
                continue
            
            if content.count(meta_with_lib_str) > 1:
                logging.warning(f"'{pkg_name}': File contains multiple '{meta_with_lib_str}', permanently skipping.")
                with master_lock: skipped_list.add(pkg_name)
                continue

            task_queue.put(ProcessingTask(pkg_name, attr_path, source_path))
        except Exception as e:
            logging.error(f"Producer error for '{pkg_name}': Unexpected error. Will retry.\n{e}")

    logging.info("Producer finished: all potential packages have been scanned.")

def eval_meta(pkg_name: str, attr_path: str) -> dict[str, Any] | None:
    try:
        cmd = ['nix', 'eval', '--impure', '--json', '--file', '.', f'{attr_path}.meta']
        result = run_command(cmd, timeout=COMMAND_TIMEOUT_S)
        return json.loads(result.stdout)
    except Exception as e:
        details = e.__notes__[0] if hasattr(e, '__notes__') and e.__notes__ else str(e)
        logging.error(f"'{pkg_name}': Meta evaluation failed.\n{details}")
        return None

def normalize_meta(obj: Any) -> Any:
    if isinstance(obj, dict):
        return {k: normalize_meta(v) for k, v in obj.items() if k not in IGNORE_KEYS_IN_META}
    if isinstance(obj, list):
        return [normalize_meta(i) for i in obj]
    return obj

def patch_meta_file(file_path: Path) -> bool:
    try:
        original_content = file_path.read_text('utf-8')
        
        meta_pattern = re.compile(r"(\bmeta\s*=\s*(?:with\s+lib\s*;\s*)?)({)")
        match = meta_pattern.search(original_content)
        if not match: return False

        meta_header_start_index = match.start(0)
        brace_open_index = match.start(2)
        brace_close_index = find_matching_brace(original_content, brace_open_index)
        if brace_close_index == -1: return False

        prefix = original_content[:meta_header_start_index]
        meta_attr_text = original_content[meta_header_start_index : brace_close_index + 1]
        suffix = original_content[brace_close_index + 1:]
        
        strings, i = [], 0
        def repl(m): nonlocal i; strings.append(m.group(0)); res = f"___S_{i}___"; i+=1; return res
        code_only_meta = re.sub(r"''((?:.|\n)*?)''|\"((?:\\.|[^\"\\])*)\"", repl, meta_attr_text)
        
        modified_code = code_only_meta
        modified_code = re.sub(r'(\bmeta\s*=\s*)with\s+lib\s*;\s*', r'\1', modified_code, count=1)

        lib_attrs = ["licenses", "maintainers", "platforms", "sourceTypes", "teams", 
                     "hydraPlatforms", "badPlatforms", "versions"]
        for attr in lib_attrs:
            modified_code = re.sub(r'(\s*=\s*with\s+)' + re.escape(attr) + r'(\s*;)', rf'\1lib.{attr}\2', modified_code)
            modified_code = re.sub(r'\b' + re.escape(attr) + r'\.', f'lib.{attr}.', modified_code)

        bare_lib_funcs = ["optionals", "optional", "mkIf", "mkMerge", "replaceStrings", "isOlder", "versionOlder", 
                          "attrNames", "length", "intersectLists", "hasInfix", "subtractLists", "optionalString",
                          "versionAtLeast"]
        for func in bare_lib_funcs:
            modified_code = re.sub(r'(?<!\.)\b' + re.escape(func) + r'\b', f'lib.{func}', modified_code)
            
        modified_code = re.sub(r'lib\.lib\.', 'lib.', modified_code)
        
        modified_meta_attr_text = modified_code
        for i, s in enumerate(strings):
            modified_meta_attr_text = modified_meta_attr_text.replace(f"___S_{i}___", s)
        
        new_content = prefix + modified_meta_attr_text + suffix
        if new_content != original_content:
            with open(file_path, "w", encoding="utf-8") as f:
                f.write(new_content)
                f.flush()
                os.fsync(f.fileno())
            return True
        return False
    except IOError as e:
        logging.error(f"I/O Error patching file {file_path}: {e}")
        return False

def worker(task_queue: Queue, processed_list: set[str]):
    while not stop_event.is_set():
        try:
            task = task_queue.get(timeout=1)
        except Empty:
            continue
        
        # This whole block is now parallel. The lock is only acquired on failure.
        try:
            with in_flight_lock: in_flight_tasks[task.pkg_name] = task.source_path
            
            logging.info(f"Processing '{task.pkg_name}'...")
            
            original_meta = eval_meta(task.pkg_name, task.attr_path)
            if original_meta is None: raise RuntimeError("Initial meta evaluation failed.")

            if not patch_meta_file(task.source_path):
                raise RuntimeError("Patching resulted in no changes, which is unexpected.")

            new_meta = eval_meta(task.pkg_name, task.attr_path)
            if new_meta is None: raise RuntimeError("Meta evaluation failed after patching.")

            norm_original, norm_new = normalize_meta(original_meta), normalize_meta(new_meta)
            if norm_original == norm_new:
                logging.info(f"[SUCCESS] '{task.pkg_name}': Refactored and verified.")
                with master_lock: processed_list.add(task.pkg_name)
            else:
                diff = DeepDiff(norm_original, norm_new, ignore_order=True, report_repetition=True)
                raise RuntimeError(f"Meta verification failed: JSON representation changed.\n{diff.pretty()}")

        except Exception as e:
            logging.error(f"Worker failed on '{task.pkg_name}': {e}. Reverting file with git.")
            
            # Add to the list of files that need cleanup.
            with failed_files_lock:
                failed_files_during_run.add(task.source_path)

            # RELIABILITY: Acquire lock ONLY for the git restore operation.
            with git_lock:
                try:
                    run_command(['git', 'restore', str(task.source_path)], timeout=10)
                    logging.info(f"'{task.pkg_name}': File successfully restored via git.")
                except Exception as git_err:
                    logging.critical(f"'{task.pkg_name}': FAILED TO RESTORE WITH GIT! Manual intervention required. Error: {git_err}")
        finally:
            with in_flight_lock:
                if task.pkg_name in in_flight_tasks: del in_flight_tasks[task.pkg_name]
            task_queue.task_done()

def save_json_file(data: set, file_path: Path):
    try:
        logging.info(f"Saving {len(data)} items to {file_path}...")
        with file_path.open("w", encoding="utf-8") as f:
            json.dump(sorted([str(p) for p in data]), f, indent=2)
    except IOError as e:
        logging.error(f"Could not save file {file_path}: {e}")

def load_json_file(file_path: Path) -> set[str]:
    if file_path.exists():
        try:
            return set(json.load(file_path.open("r", encoding="utf-8")))
        except (IOError, json.JSONDecodeError) as e:
            logging.warning(f"Could not load or parse {file_path}: {e}. Starting fresh.")
    return set()

def signal_handler(signum, frame):
    if not stop_event.is_set():
        logging.warning("\nShutdown signal received. Stopping new tasks and cleaning up...")
        stop_event.set()

# --- Main Execution ---

if __name__ == "__main__":
    logging.info("--- Script started ---")
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    processed_list = load_json_file(PROCESSED_FILE)
    skipped_list = load_json_file(SKIPPED_FILE)
    already_handled = processed_list.union(skipped_list)

    all_package_names = list_all_package_names()
    if not all_package_names: exit(1)

    task_queue = Queue(maxsize=MAX_WORKERS * 2)
    
    packages_to_scan = [pkg for pkg in all_package_names if pkg not in already_handled]
    logging.info(f"Starting to scan {len(packages_to_scan)} packages.")

    producer_thread = threading.Thread(
        target=produce_tasks,
        args=(packages_to_scan, already_handled, task_queue, skipped_list),
        name="Producer"
    )
    producer_thread.daemon = True
    producer_thread.start()

    workers = [threading.Thread(target=worker, args=(task_queue, processed_list), name=f"Worker-{i+1}", daemon=True) for i in range(MAX_WORKERS)]
    for t in workers: t.start()

    last_save_time = time.time()
    try:
        while producer_thread.is_alive() or not task_queue.empty():
            time.sleep(1)
            if time.time() - last_save_time > SAVE_PROGRESS_INTERVAL_S:
                with master_lock:
                    save_json_file(processed_list, PROCESSED_FILE)
                    save_json_file(skipped_list, SKIPPED_FILE)
                last_save_time = time.time()
            if stop_event.is_set():
                break
        
        producer_thread.join()
        task_queue.join()
        
    except (KeyboardInterrupt, SystemExit):
        logging.warning("Main thread interrupted.")
        stop_event.set()
    finally:
        logging.info("Main loop finished. Starting cleanup...")
        stop_event.set()
        
        for t in workers: t.join(timeout=2)

        # First pass of cleanup for tasks that were running during shutdown.
        with in_flight_lock:
            if in_flight_tasks:
                logging.warning(f"Reverting {len(in_flight_tasks)} in-flight tasks due to shutdown...")
                for pkg, path in in_flight_tasks.items():
                    with failed_files_lock: failed_files_during_run.add(path)
        
        # RELIABILITY: Secondary, single-threaded restore for ALL failed files.
        if failed_files_during_run:
            logging.warning(f"Performing secondary, single-threaded restore for {len(failed_files_during_run)} files...")
            with git_lock: # Use the lock for this final, critical operation.
                for path in list(failed_files_during_run):
                    try:
                        run_command(['git', 'restore', str(path)], timeout=10)
                        logging.info(f"  Secondary restore successful for: {path}")
                    except Exception as e:
                        logging.critical(f"  SECONDARY RESTORE FAILED for: {path}! Manual intervention required. Error: {e}")
            save_json_file({str(p) for p in failed_files_during_run}, FAILED_FILE)

        with master_lock: 
            save_json_file(processed_list, PROCESSED_FILE)
            save_json_file(skipped_list, SKIPPED_FILE)
            
        logging.info("--- Script finished ---")
