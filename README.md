# Optifacts Printer Manager

A smart print routing system that extends the standard Optifacts printing workflow to support dynamic, rule-based file distribution, sending print jobs to directories or physical printers based on database-driven rules.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Execution Chain](#execution-chain)
- [File Reference](#file-reference)
- [Installation & Setup](#installation--setup)
  - [1. Dependencies](#1-dependencies)
  - [2. File Placement](#2-file-placement)
  - [3. Permissions](#3-permissions)
  - [4. Database Procedure](#4-database-procedure)
  - [5. Integration with Optifacts](#5-integration-with-optifacts)
- [Configuration](#configuration)
  - [intercept_ps2pdf.pl](#intercept_ps2pdfpl-configuration)
  - [printer_manager.pl](#printer_managerpl-configuration)
  - [printer_manager.cfg](#printer_managercfg-configuration)
- [Command-Line Modes](#command-line-modes)
- [Directory Structure](#directory-structure)
- [Log Files](#log-files)
- [Error Codes](#error-codes)

---

## Overview

The standard Optifacts printing system routes jobs to physical printers. This project introduces a parallel workflow that intercepts print jobs destined for **PDF output** and dynamically routes the resulting files to configurable destinations (either a **directory path** or a **physical printer**) based on rules stored in an Informix database and a local configuration file.

> **Important:** This system does **not** modify or interfere with the standard Optifacts print workflow. All existing printer definitions (e.g., `PRINTERPCX`, `PRINTERLAX`) continue to function normally. The new workflow is triggered **only** when a job is sent to a PDF-configured queue.

---

## Architecture

The system is composed of three operational components:

```
┌─────────────────────────────────────────────────────────────────┐
│                     OPTIFACTS PRINT JOB                         │
│              (triggered via PDF-configured queue)               │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                       pr_LayHtm                                 │
│         Primary Optifacts printing program                      │
│   Generates a temporary PostScript (.ps) file and calls         │
│   the script defined in PS2PDF= (PS_Printers.cfg)               │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                   intercept_ps2pdf.pl                           │
│  ► Parses the .ps header for metadata (%%Title, %%Operator)     │
│  ► Renames files to: <Operator>-<Title>.ps / .pdf               │
│  ► Copies files to configured PS and PDF destination dirs       │
│  ► Converts .ps → .pdf via ps2pdf (with timeout protection)     │
│  ► Calls printer_manager.pl (fire-and-forget, daemonized)       │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                    printer_manager.pl                           │
│  ► Extracts the job number from the filename                    │
│  ► Queries the Informix DB for the job's name set               │
│  ► Matches the name set against printer_manager.cfg             │
│  ► Routes the file: moves to a directory OR sends to printer    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Execution Chain

1. A print job is initiated through an Optifacts queue configured for PDF output.
2. Optifacts executes `/u/optifacts/bin/pr_LayHtm` for that queue.
3. `pr_LayHtm` generates a temporary PostScript file.
4. `pr_LayHtm` reads `PS_Printers.cfg` and finds `PS2PDF=` pointing to `intercept_ps2pdf.pl`.
5. `intercept_ps2pdf.pl` is executed with the `.ps` file path as an argument.
6. It extracts metadata, renames, copies, and converts the file, then spawns `printer_manager.pl`.
7. `printer_manager.pl` queries the database, reads the config, and routes the file to its final destination.

---

## File Reference

| File | Type | Description |
|---|---|---|
| `intercept_ps2pdf.pl` | Perl script | Intercepts `.ps` files, converts to PDF, calls the router |
| `printer_manager.pl` | Perl script | Core router: queries DB, matches config, dispatches files |
| `printer_manager.cfg` | Config file | Pipe-delimited routing rules (name set → destination) |
| `blueprint-v9.txt` | Documentation | Full technical specification and design document |

---

## Installation & Setup

### 1. Dependencies

#### Perl Modules

Install base modules:
```bash
sudo cpanm File::Copy
sudo cpanm File::Basename
sudo cpanm Sys::Syslog
sudo cpanm File::Path
sudo cpanm DBI
sudo cpanm Test::Pod
```

Install the Informix-specific module (must be done as root with Informix env vars set):
```bash
sudo su root
export INFORMIXDIR="/usr/ids"
export PATH="/usr/ids/bin:${PATH}"
export LD_LIBRARY_PATH="/usr/informix/lib:/usr/informix/lib/esql:/usr/ids/lib:/usr/ids/lib/esql:${LD_LIBRARY_PATH}"
export INFORMIXSERVER="informix_server_name"
export INFORMIXSQLHOSTS="/usr/informix/etc/sqlhosts.01"
export ONCONFIG="onconfig.01"
export DBD_INFORMIX_DATABASE="optifacts"
export DBD_INFORMIX_USERNAME="user_credential"
export DBD_INFORMIX_PASSWORD="user_credential"
cpanm DBD::Informix
```

#### External Programs

- `ps2pdf` - for PostScript to PDF conversion (part of Ghostscript)
- `lpstat` - for printer availability checks (part of CUPS)
- `lp` - for sending files to physical printers

### 2. File Placement

```bash
# Place and make executable
cp intercept_ps2pdf.pl /path/to/intercept_ps2pdf.pl
cp printer_manager.pl  /usr/local/bin/printer_manager.pl
cp printer_manager.cfg /u/optifacts/share/latam_duties/printerManager/printer_manager.cfg

chmod 755 /path/to/intercept_ps2pdf.pl
chmod 755 /usr/local/bin/printer_manager.pl
```

### 3. Permissions

The printing service runs as a low-privilege user (typically `lp`). This user **must** have write permissions on all working directories:

```bash
chmod -R o+w /u/optifacts/share/latam_duties/printerManager
chmod -R o+w /u/optifacts/share/worktickets
```

### 4. Database Procedure

Create the following stored procedure in the Informix `optifacts` database:

```sql
CREATE PROCEDURE printer_manager(job_number INT)
    RETURNING VARCHAR(20) AS printer_rule;
    DEFINE _printer_rule VARCHAR(10);
    SELECT *
    INTO   _printer_rule
    FROM (
        SELECT FIRST 1 def_value
        FROM   job_data
        WHERE  def_name[1,10] = 'GROUP NAME'
        AND    def_value[1,3]  = '#P:'
        AND    def_number      = job_number
        ORDER BY def_name ASC
    );
    RETURN TRIM(_printer_rule[4,10]);
END PROCEDURE;
```

> The procedure receives a job number and returns the **name set** associated with that job (stripped of the `#P:` prefix).

### 5. Integration with Optifacts

Edit `/u/optifacts/printer.dbs/PS_Printers.cfg` for the target PDF queue and set:

```
PS2PDF=/path/to/intercept_ps2pdf.pl
```

> To revert to standard behavior at any time, change `PS2PDF=` back to `/usr/bin/ps2pdf`.

---

## Configuration

### `intercept_ps2pdf.pl` Configuration

All configuration is in the **CONFIGURATION VARIABLES** section at the top of the script.

| Variable | Type | Description |
|---|---|---|
| `$WORKING_DIR` | Path | Primary directory for logs and working files |
| `@PS_DESTINATIONS` | Array of paths | Directories where the `.ps` file will be copied |
| `@PDF_DESTINATIONS` | Array of paths | Directories where the `.pdf` file will be copied |
| `$DIR_PERMISSIONS` | Octal | Permissions for directories created by this script (e.g., `0777`) |
| `$FILE_PERMISSIONS` | Octal | Permissions for output files (e.g., `0666`) |
| `$HEADER_SCAN_LIMIT` | Integer | Number of lines to scan in the `.ps` header for metadata |
| `$REAL_PS2PDF` | Path | Full path to the `ps2pdf` binary |
| `$TEMP_DIR` | Path | Temporary directory for in-progress PDF conversion |
| `$PDF_CONVERSION_TIMEOUT` | Seconds | Max time allowed for PDF conversion (0 = no timeout) |
| `$CALL_EXEC_PS` | Path | External program to call with the `.ps` file path |
| `$DIR_FILES_TO_EXEC_PS` | Path | Directory prefix passed to the PS external program |
| `$CALL_EXEC_PDF` | Path | External program to call with the `.pdf` file path |
| `$DIR_FILES_TO_EXEC_PDF` | Path | Directory prefix passed to the PDF external program |
| `$VERBOSE_LOG` | 0 / 1 | Includes executed commands in the log when enabled |

**Example:disabling PS file saving:**
```perl
my @PS_DESTINATIONS = ();
```

**Example:multiple PDF destinations:**
```perl
my @PDF_DESTINATIONS = (
    "/u/optifacts/share/latam_duties/printerManager/intercept_ps2pdf_output",
    "/u/optifacts/share/worktickets",
);
```

---

### `printer_manager.pl` Configuration

All configuration is in **Section 4** of the script.

#### File Paths & Permissions

| Variable | Description | Example |
|---|---|---|
| `$working_directory` | Top-level directory for all operational files | `/u/optifacts/share/latam_duties/printerManager` |
| `$config_file` | Full path to `printer_manager.cfg` | `/u/optifacts/share/latam_duties/printerManager/printer_manager.cfg` |
| `$check_dir_4_lost_files` | Directory to monitor for "lost" files (empty = disabled) | `/u/optifacts/share/latam_duties/printerManager` |
| `$default_permission` | Octal permissions for created files/dirs | `0666` |

#### Behavioral Settings

| Variable | Description | Default |
|---|---|---|
| `$verbose_logging` | Enable/disable verbose log (1/0) | `0` |
| `$wait_before_1st_try` | Seconds to wait before first file access attempt | `2` |
| `$max_times_to_retry` | Additional attempts to find the file after first failure (max 5) | `1` |
| `$seconds_between_retries` | Seconds between retry attempts (min 5, max 60) | `5` |
| `$max_exec_time` | Max total execution time in seconds before auto-termination | `180` |
| `$time_2_check_lost_files` | File age in seconds to consider a file "lost" | `300` |
| `$save_processed_files` | Archive processed files instead of deleting (1/0) | `0` |

#### Commands & Patterns

| Variable | Description | Example |
|---|---|---|
| `$job_regex_pattern` | Regex to extract job number from filename | `qr/-(\d+)-/` |
| `$printer_check_command` | Command to list available printers | `lpstat -v` |
| `$command_for_printing` | Print command template with placeholders | `lp -d <printer_name> -o raw <file_path>` |
| `$ifx_procedure` | SQL to call the stored procedure | `CALL printer_manager(<job_number>)` |

#### Informix Database Connection

| Variable | Description |
|---|---|
| `$db_user` | Database username |
| `$db_password` | Database password |
| `$db_name` | Database name (e.g., `optifacts`) |
| `$informix_libs` | Colon-separated Informix library paths for `LD_LIBRARY_PATH` |
| `$ENV{'INFORMIXDIR'}` | Path to Informix installation directory |
| `$ENV{'INFORMIXSERVER'}` | Informix server instance name |
| `$ENV{'INFORMIXSQLHOSTS'}` | Path to the `sqlhosts` connection file |
| `$ENV{'ONCONFIG'}` | Name of the Informix `onconfig` file |

---

### `printer_manager.cfg` Configuration

A pipe-delimited (`|`) plain-text file that maps job name sets to routing destinations.

#### File Format

```
<NAME_SET> | <user_name or default> | <PDF or PS> | <DIRECTORY or PRINTER_NAME>
```

#### Rules & Notes

1. All `<NAME_SET>` values in Optifacts (menu 3-11-14-2) must start with `#P:`. The `#P:` prefix is **not** included in the config file; it is stripped by the database procedure before matching.
2. Avoid these characters in name set values: `:` `|` `/` `#`
3. Leading and trailing whitespace is ignored: `"  ABC  "` is read as `"ABC"`.
4. Internal spaces are preserved: `"AAA BBB"` remains `"AAA BBB"`.
5. Lines beginning with `#` are treated as comments.
6. Rules with a specific `<user_name>` take **precedence** over `default` rules for the same name set.
7. If `<DIRECTORY or PRINTER_NAME>` starts with `/`, the file is **moved to that directory**. Otherwise, it is treated as a **printer name**.

#### Example

```
# Route job group ABCDE to different directories based on user
ABCDE      | default  | PDF | /u/optifacts/share/latam_duties/printerManager/dir_1
ABCDE      | user_name | PDF | /u/optifacts/share/latam_duties/printerManager/dir_2

# Route a special group to a physical printer (PS format)
# MYGROUP  | default  | PS  | printer_lax
```

---

## Command-Line Modes

`printer_manager.pl` accepts exactly one argument. If no argument or an invalid one is provided, the help text is shown.

| Argument | Mode | Description |
|---|---|---|
| `<file_path>` | **Standard Processing** | Primary mode. Routes the given file to its destination. Called automatically by `intercept_ps2pdf.pl`. |
| `-connection` | **Connection Test** | Tests the Informix database connection and prints the result to the console. |
| `-pause` | **Pause** | Pauses processing. Incoming files are held in the `paused/` directory instead of being routed. |
| `-continue` | **Resume** | Resumes normal operation and reprocesses all files accumulated while paused. |
| `-redo` | **Reprocess** | Reprocesses all files currently in the `unprocessed/` quarantine directory. |
| `-help` | **Help** | Displays a summary of all available modes and exits. |

**Usage examples:**
```bash
# Test database connectivity
printer_manager.pl -connection

# Pause the system before maintenance
printer_manager.pl -pause

# Resume and process any backlogged files
printer_manager.pl -continue

# Reprocess files that previously failed
printer_manager.pl -redo
```

---

## Directory Structure

All directories are created automatically under `$working_directory` if they do not exist. If `$working_directory` itself is unwritable, the script falls back to a temporary directory under `/tmp/`.

```
$working_directory/
│
├── printer_manager.cfg          ← Routing rules configuration file
├── printer_manager.log          ← Success log
├── printer_manager_failures.log ← Error/failure log
├── printer_manager_verbose.log  ← Verbose diagnostics log (if enabled)
├── mode.cfg                     ← Runtime status file: "online" or "paused"
│
├── in_process/                  ← Temporary holding area while a file is being routed
├── unprocessed/                 ← Quarantine for files that failed routing
├── paused/                      ← Files received while the system was paused
├── processed/                   ← Archive of successfully processed files (if enabled)
└── intercept_ps2pdf_output/     ← Output directory from intercept_ps2pdf.pl
```

---

## Log Files

### `intercept.log` (from `intercept_ps2pdf.pl`)

```
YYYY-MM-DD|HH:MM:SS|PDF:Cx/yS|PS:Cx/yF|<Title>|<original_ps_filename>
```

- `Cx/y` - `x` successful copies out of `y` configured destinations
- Final character: `S` (external program succeeded), `F` (failed), `-` (not configured)

### `printer_manager.log` (from `printer_manager.pl`)

```
YYYY-MM-DD|HH:MM:SS|<filename>|<STATUS>|<ACTION>|<DESTINATION>
```

- `STATUS`: `PROCESSED`, `PAUSED`, `REPROCESSED_OK`, `REPROCESSED_FAIL`
- `ACTION`: `MOVE` (file moved to directory) or `PRINT` (sent to printer)

### `printer_manager_failures.log`

All errors with their corresponding error codes (F1–F24). See the [Error Codes](#error-codes) section below.

---

## Error Codes

| Code | Description |
|---|---|
| F1 | Missing required Perl module at startup |
| F3 | Invalid command-line argument |
| F4 | Database connection test failed |
| F5 | Failed to write to the mode file |
| F6 | Execution timeout (`$max_exec_time` exceeded) |
| F7 | Failed to extract job number from filename |
| F8 | Failed to extract file format from filename |
| F9 | Failed to connect to Informix database |
| F10 | Failed to execute the stored procedure |
| F11 | Stored procedure returned null or empty result |
| F12 | Configuration file could not be read |
| F13 | No matching rule found in configuration file |
| F14 | Destination directory does not exist |
| F15 | Failed to move file to destination directory |
| F16 | Printer check command failed |
| F17 | Printer name not found in `lpstat` output |
| F18 | Print command execution failed |
| F19 | "Lost" file detected and moved to unprocessed |
| F20 | Fatal: could not create working directory or fallback |
| F21 | Fatal: working directory unwritable and config file unreadable |
| F22 | File not found on retry attempt |
| F23 | File not found after all retry attempts exhausted |
| F24 | Stale file detected in `in_process/` and moved to unprocessed |

---

## Authors

- Gabriel Ramalho - First version (2025-07-24)
