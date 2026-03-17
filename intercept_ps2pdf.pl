#!/usr/bin/perl

use strict;
use warnings;
use File::Copy qw(move copy);
use File::Basename qw(basename);
use Fcntl ':flock';
use Sys::Syslog;
use POSIX 'setsid';

# ==============================================================================
#                               intercept_ps2pdf.pl
#      		A post-processor for Optifacts printing workflows.
# ==============================================================================
#	MODIFICATION HISTORY:                                                  
#                                                                           
#   YYYY-MM-DD		PERSON				DESCRIPTION                                
#   2025-07-24		Gabriel Ramalho		First version. 
#                                                                           
#===============================================================================
#
# PURPOSE:
# This script is a "man-in-the-middle" post-processor for the Optifacts `pr_LayHtm`
# printing program. It is not a general system-wide filter. Its execution is
# entirely conditional and only occurs when it is explicitly configured in the
# Optifacts printer configuration file: `/u/optifacts/printer.dbs/PS_Printers.cfg`.
#
# When `pr_LayHtm` receives the `PS2PDF=/path/intercept_ps2pdf.pl` parameter,
# this script replaces the standard PDF conversion step. This allows it to
# intercept the final PostScript (.ps) file after it has been generated and
# perform a set of actions over it.
#
# IMPORTANT TO HIGHLIGHT:
# 	- This script only applies if the menu 3-5 triggers a PDF destination. 
#	- It means that all other regular printing settings remains the same,
#	even the 3-11-14-2 "PRINTERPCX" and "PRINTERLAX". 
#
# CORE FEATURES:
#   - Intercepts the final .ps file from a primary print program (e.g., pr_LayHtm) 
#	  by replacing the standard PDF conversion step in that program's workflow.
#   - Parses the PostScript header to extract key metadata (e.g., %%Title, %%Operator).
#   - Dynamically renames output files based on the extracted metadata to the
#     format: "<Operator>-<Title>".
#   - Saves the original .ps file and/or a converted .pdf file to one or more
#     configurable destination directories.
#   - Optionally triggers external programs/scripts after file creation, passing
#     the new filename as an argument for further processing.
#   - Includes a configurable timeout for PDF conversion to prevent print queue stalls.
#   - Maintains separate, detailed logs for successful operations and failures.
#
# WORKFLOW & SCOPE OF OPERATION:
# This script only runs when explicitly called. It will NOT interfere with other
# printers or processes on the system. The exact chain of events is:
#   1. A print job is initiated through an Optifacts printer queue (e.g., LayPDF).
#   2. The printing system executes the primary program for that queue (e.g., pr_LayHtm).
#   3. The `pr_LayHtm` program generates a temporary PostScript file.
#   4. `pr_LayHtm` then reads its configuration file (`PS_Printers.cfg`) and finds the
#      `PS2PDF=` parameter, which we have set to point to THIS script.
#   5. `pr_LayHtm` executes THIS script, passing the temporary .ps file to it.
#      This is the interception point.
#
# ==============================================================================
# ---                        SETUP INSTRUCTIONS                              ---
# ==============================================================================
#
# 1. PLACEMENT:
#    Place this script in a standard executable path.
#    Make sure it is executable by all users: chmod 755 /path/intercept_ps2pdf.pl
#
# 2. CONFIGURATION:
#    Modify the "CONFIGURATION VARIABLES" section below to match the environment's
#    needs (e.g., destination paths, log file locations).
#
# 3. INTEGRATION:
#    Edit the /u/optifacts/printer.dbs/intercept_ps2pdf.cfg file. For the desired
#    printer entry (e.g., [LayPDF]), set the PS2PDF parameter to point to this script:
#      PS2PDF=/path/intercept_ps2pdf.pl
#
# 4. DIRECTORY PERMISSIONS (CRITICAL):
#    The system's printing service runs as a low-privilege user (often 'lp' on Linux
#    systems). This user MUST have write permissions for ALL directories listed in
#    @PS_DESTINATIONS, @PDF_DESTINATIONS, and the $WORKING_DIR.
#
# 5. LOGGING:
#    - Logs are automatically created in the $WORKING_DIR.
#    - Successful jobs are logged to 'intercept.log'. The format is:
#      YYYY-MM-DD|HH:MM:SS|PDF:Cx/yS|PS:Cx/yF|<Title>|original_ps_file_name
#      Where 'Cx/y' means 'x' copies succeeded out of 'y' total configured destinations.
#      The final character is the external program (if any) execution status: 
#		S (Success), F (Failure), or - (Not run).
#    - Any errors are logged to 'intercept_failure.log'.
#    - If the $WORKING_DIR is unwritable, a fallback log is created in $TEMP_DIR.
#    - Critical system-level errors are sent to the system's main log (syslog).
#
# ==============================================================================
# ---                       CONFIGURATION VARIABLES                          ---
# ==============================================================================

# 1. WORKING_DIR: The primary directory for this script's operation.
#    Log files will be created here. It will be created if it doesn't exist.
my $WORKING_DIR = "/u/optifacts/share/latam_duties/printerManager";

# 2. PS_DESTINATIONS: An array of directories to save the PostScript (.ps) file to.
#    To disable saving the .ps file, make the array empty: my @PS_DESTINATIONS = ();
#    Each directory will be created if it does not exist.
my @PS_DESTINATIONS = (
	'/u/optifacts/share/latam_duties/printerManager/intercept_ps2pdf_output',
);

# 3. PDF_DESTINATIONS: An array of directories to save the generated PDF file to.
#    To disable creating a PDF, make the array empty: my @PDF_DESTINATIONS = ();
#    Each directory will be created if it does not exist.
my @PDF_DESTINATIONS = (
    "/u/optifacts/share/latam_duties/printerManager/intercept_ps2pdf_output",
    "/u/optifacts/share/worktickets",
);

# 4. PERMISSIONS: Numeric permissions (e.g., 0777) for created items.
#    - $DIR_PERMISSIONS: For any directories created by this script.
#    - $FILE_PERMISSIONS: For all output files (PS, PDF, and logs).
my $DIR_PERMISSIONS  = 0777;
my $FILE_PERMISSIONS = 0666;

# 5. HEADER_SCAN_LIMIT: How many lines to read from the .ps file header to find metadata.
my $HEADER_SCAN_LIMIT = 50;

# 6. REAL_PS2PDF: The path to the actual ps2pdf executable.
my $REAL_PS2PDF = "/usr/bin/ps2pdf";

# 7. TEMP_DIR: A dedicated directory for temporary files created by this script.
#    This directory will be created if it does not exist.
my $TEMP_DIR = "/tmp/intercept_ps2pdf";

# 8. PDF_CONVERSION_TIMEOUT: Timeout for PDF conversion in seconds.
#    Set to 0 to disable the timeout.
#    It avoids having the printing service busy if ps2pdf takes a long time to process.
my $PDF_CONVERSION_TIMEOUT = 60; # e.g., 60 seconds

# 9. EXTERNAL PROGRAM EXECUTION:
#    Allows passing .ps or .pdf files as parameters to an external program.
#    The idea is that you'll need to state this directory also at the top
#    @PDF_DESTINATIONS or @PS_DESTINATIONS variables, so the external program,
#    if needed, may find the file there.
#	 External program invocation example: 
#		1) $CALL_EXEC_PDF<whitespace>$DIR_FILES_TO_EXEC_PDF/<operator><title>.pdf
#		or/and
#		2) $CALL_EXEC_PS<whitespace>$DIR_FILES_TO_EXEC_PS/<operator><title>.ps
my $CALL_EXEC_PS = "/u/optifacts/share/latam_duties/bin/printer_manager.pl"; # e.g., "/usr/local/bin/process_ps_hook.sh"
my $DIR_FILES_TO_EXEC_PS = "/u/optifacts/share/latam_duties/printerManager/intercept_ps2pdf_output/"; # e.g., "/mnt/ps_processing/"

my $CALL_EXEC_PDF = '/u/optifacts/share/latam_duties/bin/printer_manager.pl';
my $DIR_FILES_TO_EXEC_PDF = "/u/optifacts/share/latam_duties/printerManager/intercept_ps2pdf_output/";

# 10. VERBOSE LOGGING:
#     Set to 1 to include the full text of executed external commands in the logs.
my $VERBOSE_LOG = 0;


# ==============================================================================
# ---                         END OF CONFIGURATION                           ---
# ==============================================================================

# --- Global Log Paths (defined after configuration) ---
my $SUCCESS_LOG_PATH = "$WORKING_DIR/intercept.log";
my $FAILURE_LOG_PATH = "$WORKING_DIR/intercept_failure.log";

# --- Subroutines ---

# Ensures a directory exists, creating it with specified permissions if needed.
sub ensure_directory_exists {
    my ($dir_path, $permissions, $no_exit_on_fail) = @_;
    
    # If directory already exists, we're done.
    return 1 if (-d $dir_path);

    # Try to create the directory.
    if (mkdir($dir_path, $permissions)) {
        syslog('info', "Created directory '%s'", $dir_path);
        return 1;
    }
    
    # Creation failed.
    my $error = "Failed to create directory '$dir_path': $!";
    syslog('error', 'CRITICAL: %s', $error);

    # In a loop, we might not want to exit, so we log and return failure.
    if ($no_exit_on_fail) {
        # We can't use log_failure here as it could lead to a loop.
        return 0;
    }
    
    # For critical directories like WORKING_DIR, exit the script.
    closelog();
    exit 1;
}

sub parse_ps_header {
    my ($file_path, $line_limit) = @_;
    my $title = 'UNKNOWN_TITLE';
    my $operator = 'UNKNOWN_OPERATOR';
    open(my $fh, '<', $file_path) or return ($title, $operator);
    my $lines_read = 0;
    while (my $line = <$fh>) {
        last if $lines_read++ >= $line_limit;
        if ($line =~ /^%%Title:\s*(.*)/) {
            $title = $1;
            $title =~ s/^\s+|\s+$//g;
        }
        if ($line =~ /^%%Operator\s+(.*)/) {
            $operator = $1;
            $operator =~ s/^\s+|\s+$//g;
        }
        last if ($title ne 'UNKNOWN_TITLE' && $operator ne 'UNKNOWN_OPERATOR');
    }
    close $fh;
    return ($title, $operator);
}

# Sanitizes a string for safe inclusion in a pipe-delimited log.
sub sanitize_for_log {
    my ($string_to_clean) = @_;
    return '' unless defined $string_to_clean;
    $string_to_clean =~ s/\|/;/g;  # Replace pipe with semicolon to preserve data
    $string_to_clean =~ s/[\n\r]/ /g; # Replace newlines/returns with a space
    return $string_to_clean;
}

# Log failures and returns 0 on failure, 1 on success.
sub call_external_program {
    my ($executable, $dir_prefix, $filename, $title, $original_basename) = @_;
    return -1 unless ($executable && defined $dir_prefix); # -1 means not configured

    unless (-x $executable) {
        my $error = "Executable '$executable' not found or not executable.";
        log_failure($title, $original_basename, $error);
        return 0; # 0 means launch failed
    }

    my $argument = "$dir_prefix$filename";

    # Daemonize the external program using a double-fork.
    my $pid = fork();
    if (!defined $pid) {
        my $error = "CRITICAL: First fork failed: $!";
        if ($VERBOSE_LOG) {
            $error .= " Command: $executable '$argument'";
        }
        log_failure($title, $original_basename, $error);
        return 0; # 0 means launch failed
    }

    if ($pid) {
        # PARENT: The launch was successful. Return immediately (fire-and-forget).
        return 1; # 1 means launch succeeded
    }

    # CHILD 1: Detach from parent and terminal.
    setsid() or die "Can't start a new session: $!"; # Becomes session leader

    my $grandchild_pid = fork();
    if (!defined $grandchild_pid) {
        # Log to syslog since we are detached.
        syslog('error', "CRITICAL: Second fork failed for '$executable': $!");
        exit 1; # Child 1 exits with an error
    }

    if ($grandchild_pid) {
        # CHILD 1: Purpose fulfilled. Exit immediately so grandchild is orphaned to init.
        exit 0;
    }

    # GRANDCHILD: Now fully daemonized.
    # Close filehandles and redirect to /dev/null.
    close STDIN;
    close STDOUT;
    close STDERR;
    open STDIN, '<', '/dev/null';
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', '/dev/null';

    # Replace this process with the executable.
    exec($executable, $argument) or syslog('error', "Exec failed for '$executable' with arg '$argument': $!");

    # This should never be reached unless exec() fails.
    exit 127;
}

# Subroutine to log failures.
sub log_failure {
    my ($title, $original_basename, $error_message) = @_;
    my $timestamp = get_timestamp();
    
    # Sanitize all components to prevent log corruption.
    my $s_title = sanitize_for_log($title);
    my $s_basename = sanitize_for_log($original_basename);
    my $s_error = sanitize_for_log($error_message);
    
    my $log_entry = join('|', $timestamp, $s_title, $s_basename, $s_error);
    
    # Use fallback logic for the failure log.
    my $log_fh;
    my $log_file_was_missing = !(-e $FAILURE_LOG_PATH);
    unless(open($log_fh, '>>', $FAILURE_LOG_PATH)) {
        my $fallback = "$TEMP_DIR/intercept_failure.log";
        $log_file_was_missing = !(-e $fallback);
        unless(open($log_fh, '>>', $fallback)) {
            syslog('error', "CRITICAL: Could not write failure to primary log or fallback: %s", $log_entry);
            return;
        }
        # Set permissions on the newly created fallback log.
        if ($log_file_was_missing) {
            chmod($FILE_PERMISSIONS, $fallback) or syslog('warning', "Could not set permissions on fallback log '%s': %s", $fallback, $!);
        }
    }
    flock($log_fh, LOCK_EX);
    print $log_fh "$log_entry\n";
    flock($log_fh, LOCK_UN);
    close $log_fh;

    # Set permissions if the primary log file was just created.
    if ($log_file_was_missing) {
        chmod($FILE_PERMISSIONS, $FAILURE_LOG_PATH) or syslog('warning', "Could not set permissions on log '%s': %s", $FAILURE_LOG_PATH, $!);
    }
}

sub get_timestamp {
    my ($sec, $min, $hour, $mday, $mon, $year) = localtime();
    return sprintf("%04d-%02d-%02d|%02d:%02d:%02d", $year+1900, $mon+1, $mday, $hour, $min, $sec);
}

# --- Main Script Logic ---
openlog('intercept_ps2pdf', 'pid', 'local0');

# Set umask to 0 to ensure permissions are set as specified, then restore it on exit.
my $old_umask = umask(0);

# --- Initial Setup ---
# Ensure critical directories exist before proceeding.
ensure_directory_exists($WORKING_DIR, $DIR_PERMISSIONS);
ensure_directory_exists($TEMP_DIR, $DIR_PERMISSIONS);

# Argument validation
unless (@ARGV == 2) {
    syslog('error', 'FATAL: Expected 2 arguments, received %d: %s', scalar(@ARGV), join(' ', @ARGV));
    umask($old_umask); closelog(); exit 1;
}
my ($input_ps_file, $original_pdf_target) = @ARGV;
my $original_ps_basename = basename($input_ps_file);

# Input file validation
unless (-f $input_ps_file) {
    syslog('error', "FATAL: Input file '%s' not found.", $input_ps_file);
    umask($old_umask); closelog(); exit 1;
}

# State tracking variables
my $ps_copy_successes = 0;
my $pdf_copy_successes = 0;
my $ps_exec_status = '-'; # -, S, F
my $pdf_exec_status = '-'; # -, S, F
my @verbose_log_entries = ();

# Get Dynamic Filename
my ($title, $operator) = parse_ps_header($input_ps_file, $HEADER_SCAN_LIMIT);
my $clean_title = $title;
my $clean_operator = $operator;
$clean_title    =~ s/[^\w.-]+/-/g;
$clean_operator =~ s/[^\w.-]+/-/g;
my $new_basename = "$clean_operator-$clean_title";

# Process Destinations
my $pdf_generated_path;

# Handle PS Destinations
if (@PS_DESTINATIONS) {
    foreach my $dir (@PS_DESTINATIONS) {
        # Ensure the destination directory exists, creating it if necessary.
        if (ensure_directory_exists($dir, $DIR_PERMISSIONS, 1)) {
            my $dest_path = "$dir/$new_basename.ps";
            if (copy($input_ps_file, $dest_path)) {
                chmod($FILE_PERMISSIONS, $dest_path) or syslog('warning', "Could not set permissions on '%s': %s", $dest_path, $!);
                $ps_copy_successes++;
            } else {
                log_failure($title, $original_ps_basename, "Failed to copy PS to '$dest_path': $!");
            }
        } else {
            log_failure($title, $original_ps_basename, "PS destination '$dir' could not be created or accessed.");
        }
    }
    
    # Check and execute external PS program
    if ($CALL_EXEC_PS) {
        my $ps_exec_target_file = "$DIR_FILES_TO_EXEC_PS/$new_basename.ps";
        if ($VERBOSE_LOG) {
            push @verbose_log_entries, "PS_CMD: $CALL_EXEC_PS '$ps_exec_target_file'";
        }
        if (-f $ps_exec_target_file) {
            my $exec_result = call_external_program($CALL_EXEC_PS, $DIR_FILES_TO_EXEC_PS, "$new_basename.ps", $title, $original_ps_basename);
            $ps_exec_status = 'S' if $exec_result == 1;
            $ps_exec_status = 'F' if $exec_result == 0;
        } else {
            log_failure($title, $original_ps_basename, "Skipped external PS program: Target file '$ps_exec_target_file' not found.");
            $ps_exec_status = 'F';
        }
    }
}

# Handle PDF Destinations
if (@PDF_DESTINATIONS) {
    my $temp_pdf_path = "$TEMP_DIR/$new_basename.$$.pdf";
    my $exit_code;
    
    # PDF conversion with timeout
    eval {
        local $SIG{ALRM} = sub { die "Timeout\n" };
        alarm($PDF_CONVERSION_TIMEOUT) if $PDF_CONVERSION_TIMEOUT > 0;
        $exit_code = system($REAL_PS2PDF, $input_ps_file, $temp_pdf_path);
        alarm(0); # Disable the alarm if it completed in time
    };
    
    if ($@) {
        my $error = "ps2pdf failed to convert '$original_ps_basename'. Reason: " . ($@ =~ /Timeout/ ? "Conversion timed out after $PDF_CONVERSION_TIMEOUT seconds." : "Script error ($@)");
        log_failure($title, $original_ps_basename, $error);
    } elsif ($exit_code == 0) {
        $pdf_generated_path = $temp_pdf_path;
        foreach my $dir (@PDF_DESTINATIONS) {
            # Ensure the destination directory exists, creating it if necessary.
            if (ensure_directory_exists($dir, $DIR_PERMISSIONS, 1)) {
                my $dest_path = "$dir/$new_basename.pdf";
                if (copy($pdf_generated_path, $dest_path)) {
                    chmod($FILE_PERMISSIONS, $dest_path) or syslog('warning', "Could not set permissions on '%s': %s", $dest_path, $!);
                    $pdf_copy_successes++;
                } else {
                    log_failure($title, $original_ps_basename, "Failed to copy PDF to '$dest_path': $!");
                }
            } else {
                log_failure($title, $original_ps_basename, "PDF destination '$dir' could not be created or accessed.");
            }
        }
        
        # Check and execute external PDF program
        if ($CALL_EXEC_PDF) {
            my $pdf_exec_target_file = "$DIR_FILES_TO_EXEC_PDF$new_basename.pdf";
            if ($VERBOSE_LOG) {
                push @verbose_log_entries, "PDF_CMD: $CALL_EXEC_PDF '$pdf_exec_target_file'";
            }
            if (-f $pdf_exec_target_file) {
                my $exec_result = call_external_program($CALL_EXEC_PDF, $DIR_FILES_TO_EXEC_PDF, "$new_basename.pdf", $title, $original_ps_basename);
                $pdf_exec_status = 'S' if $exec_result == 1;
                $pdf_exec_status = 'F' if $exec_result == 0;
            } else {
                log_failure($title, $original_ps_basename, "Skipped external PDF program: Target file '$pdf_exec_target_file' not found.");
                $pdf_exec_status = 'F';
            }
        }
    } else {
        my $error = "ps2pdf failed with exit code " . ($exit_code >> 8);
        if ($VERBOSE_LOG) {
            $error .= ". Command: $REAL_PS2PDF '$input_ps_file' '$temp_pdf_path'";
        }
        log_failure($title, $original_ps_basename, $error);
    }
}

# Clean Up Temporary Files
unlink $input_ps_file;
unlink $pdf_generated_path if $pdf_generated_path;

# Log the successful operation
my $log_fh;
my $log_file_was_missing = !(-e $SUCCESS_LOG_PATH);
unless (open($log_fh, '>>', $SUCCESS_LOG_PATH)) {
    my $fallback_log = "$TEMP_DIR/intercept.log";
    $log_file_was_missing = !(-e $fallback_log);
    unless (open($log_fh, '>>', $fallback_log)) {
        syslog('error', "CRITICAL: Could not open primary log '%s' or fallback log '%s'", $SUCCESS_LOG_PATH, $fallback_log);
        umask($old_umask); closelog(); exit 1;
    }
    syslog('warning', "Using fallback log file: %s", $fallback_log);
    # Set permissions on the newly created fallback log
    if ($log_file_was_missing) {
        chmod($FILE_PERMISSIONS, $fallback_log) or syslog('warning', "Could not set permissions on fallback log '%s': %s", $fallback_log, $!);
    }
}

my $timestamp = get_timestamp();

# --- Log status strings ---
my $ps_total_dest = scalar(@PS_DESTINATIONS);
my $ps_status = "C${ps_copy_successes}/${ps_total_dest}${ps_exec_status}";

my $pdf_total_dest = scalar(@PDF_DESTINATIONS);
my $pdf_status = "C${pdf_copy_successes}/${pdf_total_dest}${pdf_exec_status}";

my $s_title = sanitize_for_log($title);
my $s_basename = sanitize_for_log($original_ps_basename);

my $log_entry = join('|', $timestamp, "PDF:$pdf_status", "PS:$ps_status", $s_title, $s_basename);

if ($VERBOSE_LOG && @verbose_log_entries) {
    my $verbose_string = join('; ', @verbose_log_entries);
    $log_entry .= '|' . sanitize_for_log($verbose_string);
}

flock($log_fh, LOCK_EX);
print $log_fh "$log_entry\n";
flock($log_fh, LOCK_UN);
close $log_fh;

# Set permissions if the primary log file was just created
if ($log_file_was_missing) {
    chmod($FILE_PERMISSIONS, $SUCCESS_LOG_PATH) or syslog('warning', "Could not set permissions on log '%s': %s", $SUCCESS_LOG_PATH, $!);
}

umask($old_umask);
closelog();
exit 0;
