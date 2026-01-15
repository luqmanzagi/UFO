#!/usr/bin/env python3
"""
Extract errors from all log files in Nov30/log_terminal/ and output as JSON.
Each error includes the filename and the line range where it occurred.
"""

import json
import os
import re
from pathlib import Path
from typing import List, Dict, Tuple


def find_error_blocks(content: str) -> List[Tuple[int, int, str]]:
    """
    Find all error blocks in the log content.
    Returns list of tuples: (start_line, end_line, error_text)
    """
    lines = content.split('\n')
    errors = []
    i = 0
    
    while i < len(lines):
        line = lines[i]
        
        # Check for traceback start
        if 'Traceback (most recent call last):' in line:
            start_line = i + 1  # 1-indexed for output
            error_lines = [line]
            i += 1
            
            # Collect the traceback and error message
            while i < len(lines):
                current_line = lines[i]
                error_lines.append(current_line)
                
                # Check if this is the final error message (exception type)
                if re.match(r'^\d{4}-\d{2}-\d{2}', current_line):
                    # Check if line contains an exception/error
                    if any(keyword in current_line for keyword in [
                        'Error:', 'Exception:', 'ERROR', 'WARNING',
                        'Failed', 'failed', 'Error calling', 'COMError',
                        'ConnectError', 'TimeoutError', 'ValueError',
                        'KeyError', 'AttributeError', 'TypeError',
                        'FileNotFoundError', 'PermissionError'
                    ]):
                        # Check if next line doesn't continue the error
                        if i + 1 < len(lines):
                            next_line = lines[i + 1]
                            # If next line is not part of traceback/error, we're done
                            if not (next_line.strip().startswith('File ') or 
                                   next_line.strip().startswith('  File ') or
                                   'Traceback' in next_line or
                                   'The above exception' in next_line or
                                   'System.Management' in next_line):
                                break
                
                # Check for continuation patterns
                if (i + 1 < len(lines) and 
                    not lines[i + 1].strip().startswith('File ') and
                    not lines[i + 1].strip().startswith('  File ') and
                    'Traceback' not in lines[i + 1] and
                    'The above exception' not in lines[i + 1] and
                    not re.match(r'^\d{4}-\d{2}-\d{2}', lines[i + 1]) and
                    not lines[i + 1].strip().startswith('│') and
                    not lines[i + 1].strip().startswith('┌') and
                    not lines[i + 1].strip().startswith('└') and
                    not lines[i + 1].strip().startswith('─') and
                    'System.Management' not in lines[i + 1]):
                    # Check if current line looks like final error
                    if any(keyword in current_line for keyword in [
                        'Error:', 'Exception:', 'ERROR', 'COMError',
                        'ConnectError', 'TimeoutError', 'ValueError',
                        'KeyError', 'AttributeError', 'TypeError'
                    ]):
                        break
                
                i += 1
            
            end_line = i + 1  # 1-indexed
            error_text = '\n'.join(error_lines)
            errors.append((start_line, end_line, error_text))
        
        # Check for standalone error messages (without traceback)
        elif re.match(r'^\d{4}-\d{2}-\d{2}', line):
            if any(keyword in line for keyword in [
                'ERROR', 'Error calling', 'COMError', 'ConnectError',
                'Failed to get', 'failed with error'
            ]):
                # Check if it's not part of a traceback we already captured
                if not any(start <= (i + 1) <= end for start, end, _ in errors):
                    start_line = i + 1
                    end_line = i + 1
                    error_text = line
                    errors.append((start_line, end_line, error_text))
        
        i += 1
    
    return errors


def process_log_file(log_path: Path) -> Dict:
    """
    Process a single log file and extract all errors.
    Returns a dict with filename and errors.
    """
    try:
        with open(log_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
        
        errors = find_error_blocks(content)
        
        error_list = []
        for start_line, end_line, error_text in errors:
            error_list.append({
                "line_range": f"{start_line}-{end_line}",
                "start_line": start_line,
                "end_line": end_line,
                "error": error_text.strip()
            })
        
        return {
            "filename": log_path.name,
            "filepath": str(log_path),
            "error_count": len(error_list),
            "errors": error_list
        }
    
    except Exception as e:
        return {
            "filename": log_path.name,
            "filepath": str(log_path),
            "error_count": 0,
            "errors": [],
            "processing_error": str(e)
        }


def main():
    """Main function to process all log files and output JSON."""
    # Get the log directory
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    log_dir = project_root / "Nov30" / "log_terminal"
    
    if not log_dir.exists():
        print(f"Error: Log directory not found: {log_dir}", file=os.sys.stderr)
        return
    
    # Find all .log files
    log_files = sorted(log_dir.glob("*.log"))
    
    if not log_files:
        print(f"Warning: No .log files found in {log_dir}", file=os.sys.stderr)
        return
    
    # Process each log file
    results = []
    for log_file in log_files:
        result = process_log_file(log_file)
        results.append(result)
    
    # Output as JSON
    output = {
        "summary": {
            "total_files": len(log_files),
            "files_with_errors": sum(1 for r in results if r["error_count"] > 0),
            "total_errors": sum(r["error_count"] for r in results)
        },
        "files": results
    }
    
    # Handle Windows encoding issues by writing to stdout buffer
    json_output = json.dumps(output, indent=2, ensure_ascii=False)
    try:
        # Write UTF-8 directly to stdout buffer to avoid encoding issues
        os.sys.stdout.buffer.write(json_output.encode('utf-8'))
        os.sys.stdout.buffer.write(b'\n')
    except (AttributeError, UnicodeEncodeError):
        # Fallback for systems without buffer or other issues
        print(json.dumps(output, indent=2, ensure_ascii=True))


if __name__ == "__main__":
    main()

