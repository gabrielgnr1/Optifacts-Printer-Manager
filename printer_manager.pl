#!/usr/bin/perl

################################################################################
#                                printer_manager.pl
#      	Manage Optifacts Printer Rules, if called by `intercept_ps2pdf.pl`.
################################################################################
#
#	MODIFICATION HISTORY:
#
#   YYYY-MM-DD		PERSON				DESCRIPTION
#   2025-07-24		Gabriel Ramalho		First version.
#
#===============================================================================
#              SECTION 1: PROGRAM CONTEXT, FUNCTIONALITY, AND AIM
#===============================================================================

###	1.1. PURPOSE AND SCOPE

# 	The script's core objective is to determine the correct destination for a
# 	given file (`.ps` or `.pdf`) by querying a database, matching the result
# 	against a local configuration file, and then executing the appropriate
# 	action—either moving the file to a directory or sending it to a system printer.
#   This script is a command-line utility with multiple operational modes.

###	1.2. WORKFLOW INTEGRATION AND CONTEXT

# 	This script is designed to integrate with and extend the standard Optifacts printing system.
#	It is critical to understand that this special printer routing is only triggered for jobs
#	destined for PDF output and does not alter existing non-PDF printing processes.
#	
#	- Standard Behavior Unaffected: All existing PHYSICAL printer definitions and rules
#	  in Optifacts (e.g., in menus 3-5, and 3-11-14-2 rules like "PRINTERPCX" or
#	  "PRINTERLAX") will continue to function normally without any impact from this script.
#
#   - Special PDF Workflow Trigger: This new workflow is triggered ONLY when an Optifacts
#	  job destination evaluates to a PDF output queue AND the variable `PS2PDF=` parameter of
#	  the `/u/optifacts/printer.dbs/PS_Printers.cfg` file is modified to point to the 
#	  `intercept_ps2pdf.pl` script. While the trigger is a PDF queue, note that the
#     `intercept_ps2pdf.pl` script can pass either the original .ps file or a converted
#     .pdf file to this script for final routing.
#	  (Optifacts will follow the standard behavior if `PS2PDF=` is kept as `/usr/bin/ps2pdf`)
#
#	- The full execution chain is as follows:
#		1. A print job is initiated through an Optifacts printer queue configured for PDF output.
#		2. The printing system executes the primary program for that queue: `/u/optifacts/bin/pr_LayHtm`.
#		3. The `pr_LayHtm` program generates a temporary PostScript file.
#		4. `pr_LayHtm` calls `intercept_ps2pdf.pl`, which handles file naming, PDF
#		   conversion, and multi-destination copying.
#		5. `intercept_ps2pdf.pl` then calls THIS SCRIPT (`printer_manager.pl`) as an
#		   external program, passing the full path to a newly created file as a
#		   single command-line argument. This script then takes over to perform the final routing.

#===============================================================================
#                          SECTION 2: SETUP INSTRUCTIONS
#===============================================================================

# 	1. DEPENDENCIES (PRE-REQUISITES)
#	   The following components are MANDATORY for this script to run. It is essential
#	   to ensure they are installed and accessible before deployment.
#
#	   A) PERL MODULES:
#		  - File::Copy
#		  - File::Basename
#		  - Sys::Syslog
#		  - File::Path
#		  - Fcntl
#		  - DBI
#		  - Test::Pod
#		  - DBD::Informix
#	      Installation Notice: These modules must be installed on the system. They can
#	      typically be installed via the system's package manager or CPAN. As a user
#	      with appropriate permissions, the CPAN command is: `cpan Module::Name`
#	      (e.g., `cpan DBI`, `cpan DBD::Informix`).
#	      Startup Check: The script will check for these modules at startup. If any
#	      are missing, it will log a fatal error to the `$failure_log` (F1) and exit.
#	
#	    - Sequence to install base Perl modules:
#		    sudo cpanm File::Copy
#		    sudo cpanm File::Basename
#		    sudo cpanm Sys::Syslog
#		    sudo cpanm File::Path
#	
#	    - Sequence to install Informix Specific Perl Modules.
#	      Modify the export variables to match your environment context.
#		    sudo cpanm DBI
#		    sudo cpanm Test::Pod
#		    sudo su root
#			    export INFORMIXDIR="/usr/ids"
#			    export PATH="/usr/ids/bin:${PATH}"
#			    export LD_LIBRARY_PATH="/usr/informix/lib:/usr/informix/lib/esql:/usr/ids/lib:/usr/ids/lib/esql:${LD_LIBRARY_PATH}"
#			    export INFORMIXSERVER="informix_server_name"
#			    export INFORMIXSQLHOSTS="/usr/informix/etc/sqlhosts.01"
#			    export ONCONFIG="onconfig.01"
#			    export DBD_INFORMIX_DATABASE="optifacts"
#			    export DBD_INFORMIX_USERNAME="user_credential"
#			    export DBD_INFORMIX_PASSWORD="user_credential"
#			    cpanm DBD::Informix
#
#	   B) EXTERNAL PROGRAMS:
#	      The command specified in `$printer_check_command` (e.g., `lpstat`) must
#	      be installed and available in the execution environment's PATH.
#
#	   C) DATABASE:
#	      A running Informix instance with the specified stored procedure.
	
# 	2. PLACEMENT
#	   Place this script in a standard executable path, such as /usr/local/bin/printer_manager.pl
#	   Make sure it is executable by all users: `chmod 755 /usr/local/bin/printer_manager.pl`

# 	3. SCRIPT CONFIGURATION
#	   Modify the "CONFIGURATION VARIABLES" section (Section 4) below to match your
#	   environment's needs (e.g., working directory, database credentials).

# 	4. INTEGRATION WITH PRECEDING SCRIPT
#	   This script is triggered by `intercept_ps2pdf.pl`. To enable this, you must
#	   edit the configuration section of `intercept_ps2pdf.pl` and set the `$CALL_EXEC_PS`
#	   and/or `$CALL_EXEC_PDF` variables to the full path of this script. For example:
#	   `my $CALL_EXEC_PDF = "/usr/local/bin/printer_manager.pl";`

# 	5. DIRECTORY PERMISSIONS (CRITICAL)
#	   The system's printing service runs as a low-privilege user (often 'lp' on
#	   Linux systems). This user MUST have write permissions for the main `$working_directory`
#	   and all its subdirectories the script will manage.
#	   Example command to grant permissions: `chmod -R o+w /path/to/your/working_directory`
#	   This version is designed to operate with a self-contained directory structure.

# 	6. LOGGING OVERVIEW
#	   - Successful jobs are logged to the file specified in `$success_log`.
#	   - All operational and critical errors are logged to the `$failure_log`.
#	   - If verbose mode is on, detailed step-by-step diagnostics are logged to `$verbose_log`.
#	   - If the primary working directory is unwritable, the script creates and uses a
#	     fallback directory within `/tmp/`.
	
#	7. ENSURE THE EXISTENCE OF THE INFORMIX PROCEDURE CALLED BY THIS SCRIPT	
#
#	    CREATE PROCEDURE printer_manager(job_number INT) 
#		    RETURNING 	VARCHAR(20) AS printer_rule
#		    ;
#		    DEFINE		_printer_rule VARCHAR(10)
#		    ; 	
#		    SELECT		*
#		    INTO		_printer_rule
#		    FROM	(	SELECT		FIRST 1 def_value
#					    FROM		job_data
#					    WHERE		def_name[1,10] = 'GROUP NAME'
#						    AND		def_value[1,3] = '#P:'
#						    AND		def_number = job_number
#					    ORDER BY	def_name ASC
#				    )
#		    ;
#		    RETURN TRIM(_printer_rule[4,10])
#		    ;
#	    END PROCEDURE
#	    ;
#

#===============================================================================
#                          SECTION 3: COMMAND LINE MODES
#===============================================================================
# This script operates in different modes based on the command-line argument it receives.
# It expects exactly one argument to determine its behavior.

#   - `<file_path>` (Standard Processing Mode)
#     Purpose: This is the primary operational mode, triggered by the preceding
#              `intercept_ps2pdf.pl` script. It takes a full file path as an argument
#              and executes the complete routing workflow.

#   - `-connect` (Connection Test Mode)
#     Purpose: A diagnostic mode to verify connectivity to the Informix database. It
#              runs a simple query and reports success or failure to the console.

#   - `-redo` (Reprocess Mode)
#     Purpose: An administrative mode to re-process all files currently in the
#              `$unprocessed_dir`. It iterates through each file and runs the full
#              processing workflow on it.

#   - `-pause` (Pause Processing Mode)
#     Purpose: An administrative mode to gracefully pause the processing of new,
#              incoming files. It sets a status flag that causes new files to be
#              redirected to a `$paused_dir` instead of being processed.

#   - `-resume` (Resume Processing Mode)
#     Purpose: An administrative mode that resumes normal operation. It sets the status
#              flag back to "online" and then re-processes all files that were
#              accumulated in the `$paused_dir`.

#   - `-help` (Help Mode)
#     Purpose: Displays a summary of all available command-line arguments and their
#              functions, then exits.

#===============================================================================
#                SECTION 4: USER-DEFINED CONFIGURATION VARIABLES
#===============================================================================
# This entire section is read before any logic is executed.

# 	1. DEFINING FILE PATHS & PERMISSIONS
#	------------------------------------
	my $working_directory = '/u/optifacts/share/latam_duties/printerManager';
    #   Purpose: The main operational base for the script. All subdirectories
    #            (in_process, unprocessed, logs, etc.) will be created inside this
    #            directory. The script must have write permissions here. If creation
    #            fails or the directory is unwritable, the script will enter a fallback mode.
		
	my $config_file = '/u/optifacts/share/latam_duties/printerManager/printer_manager.cfg';
	#   Purpose: Full path to the pipe-delimited rule configuration file. This path is
	#            independent of the working directory and must be defined explicitly.
	#   Example Value: '/u/optifacts/share/latam_duties/printerManager/printer_manager.cfg'

	my $DIR_PERMISSIONS  = 0777;
	#   Purpose: The octal permission (e.g., 0777) applied to any directories
	#	         created by this script. Results in 'drwxrwxrwx'.
	#   Example Value: 0777
	
	my $FILE_PERMISSIONS = 0666;
	#   Purpose: The octal permission (e.g., 0666) applied to any files
	#	         (like logs) created by this script. Results in '-rw-rw-rw-'.
	#   Example Value: 0666
	
# 	2. ADJUSTING BEHAVIORAL LOGIC
#	------------------------------
	my $verbose_logging = 0;
	#   Purpose: A boolean flag (1 or 0) to enable or disable writing to the
	#	         verbose log file. Allows for turning off detailed logging in production.
	#   Example Value: 1
		
	my $wait_before_1st_try = 2;
	#   Purpose: Seconds to wait before the script's first attempt to access the
	#	         `$incoming_file`. Helps mitigate file-system race conditions.
	#   Example Value: 3
		
	my $max_times_to_retry = 1;
	#   Purpose: The number of additional attempts to find the file after the first one fails.
	#	         - This value is mandatory for the retry logic to function.
	#	         - The script will enforce a maximum value of 5. A value of 3 means 4 total attempts.
	#   Example Value: 3
	
	my $seconds_between_retries = 5;
	#   Purpose: Seconds to wait between each subsequent attempt if the file is not found.
	#	         - This value is mandatory for the retry logic to function.
	#	         - The script will enforce a minimum value of 5 and a maximum of 60.
	#   Example Value: 10
	
	my $max_exec_time = 300; # in seconds
    #   Purpose: The maximum total time in seconds that a single file processing session
    #            is allowed to run. If a file takes longer than this to process,
    #            the script will be terminated, and the file will be moved to the
    #            'unprocessed' directory to prevent it from hanging indefinitely.

	my $recheck_original_dir = '/u/optifacts/share/latam_duties/printerManager/intercept_ps2pdf_output';
	#   Purpose: Specifies a directory (typically the output directory of the preceding
	#            `intercept_ps2pdf.pl` script) to monitor for "lost" files. If a file
	#            sits in this directory for too long, this script will move it to the
	#            unprocessed folder for investigation. Set to an empty string to disable.
	#   Example Value: '/u/optifacts/share/latam_duties/printerManager'
	
	my $recheck_original_dir_file_age = 360; # in seconds
	#   Purpose: The age in seconds a file must exceed in the `$recheck_original_dir`
	#            directory to be considered "lost" and moved to unprocessed.

	my $stale_file_age_limit_seconds = 360; # in seconds
    #   Purpose: The age in seconds a file in the 'in_process' directory must
    #            exceed to be considered "stale". This is a crucial safety net
    #            to catch and recover files from previous script runs that may have
    #            crashed or been interrupted unexpectedly.

	my $save_processed_files = 0;
    #   Purpose: Controls what happens to a file ONLY after a successful PRINT action.
    #            If 1, the file is archived to the 'processed' directory.
    #            If 0, the file is permanently deleted. This does not affect files
    #            that are moved to a directory, which are always preserved.

# 	3. DEFINING COMMANDS AND REGEX PATTERNS
#	---------------------------------------
	my $job_regex_pattern = qr/-(\d+?)-/;
	#   Purpose: A Perl regular expression used to extract the job number from the
	#	         incoming filename. It must use a capture group `()` for the numerical value.
	#   Example Value: qr/-(\d+)-/

	my $user_name_regex = qr/^(\D+?)(?=-)/;
	#   Purpose: A Perl regular expression used to extract the user name from the
	#	         incoming filename. It must use a capture group `()` for the user name.
	#   Example Value: qr/_u-([^_]+)_/  (for a filename like '..._u-user_name_...')
		
	my $printer_check_command = "lpstat -v";
	#   Purpose: A shell command that lists available system printers. The script
	#	         will check this command's output to validate if a printer name exists.
	#   Example Value: 'lpstat -v'
		
	my $command_for_printing = 'lp -d <printer_name> -o raw <file_path>';
	#   Purpose: A template for the shell command used to print a file. Must
	#	         include `<printer_name>` and `<file_path>` placeholders.
	#   Example Value: 'lp -d <printer_name> -o raw <file_path>'
		
	my $ifx_procedure = 'CALL printer_manager(<job_number>)'; 
	#   Purpose: The SQL statement to call the Informix stored procedure. Must
	#	         include a `<job_number>` placeholder for the job number.
	#   Example Value: 'EXECUTE PROCEDURE get_printer_rule(<job_number>)'

#	4. VARIABLES FOR THE INFORMIX DATABASE CONNECTION
#	-----------------------------------------------
	my $db_user = 'user_credential';
	#   Purpose: The username for the database connection.
	#   Example Value: 'user_credential'
		
	my $db_password = 'user_credential';
	#   Purpose: The password for the database connection.
	#   Example Value: 'user_credential'
	
	my $db_name = 'optifacts';
	#   Purpose: The name of the specific database to connect to within the Informix instance.
	#   Example Value: 'optifacts'

	my $informix_libs = "/usr/ids/lib:/usr/ids/lib/esql:/usr/informix/lib:/usr/informix/lib/esql";
	#   Purpose: A colon-separated list of paths to the Informix client libraries,
	# 	         used to construct $ENV{'LD_LIBRARY_PATH'}.
	
	my $informix_dir = '/usr/informix';
	#   Purpose: Path to the Informix installation directory.
	#   Example Value: '/usr/informix'
		
	my $informix_server = 'informix_server_name';
	#   Purpose: The name of the default Informix server instance to connect to.
	#   Example Value: 'informix_server_name'
		
	my $informix_sqlhosts = '/usr/informix/etc/sqlhosts.01';
	#   Purpose: Full path to the `sqlhosts` file defining server connection details.
	#   Example Value: '/usr/informix/etc/sqlhosts.01'
		
	my $informix_onconfig = 'onconfig.01';
	#   Purpose: The name of the configuration file for the Informix instance.
	#   Example Value: 'onconfig.01'

#===============================================================================
#                 SECTION 4: MEANING OF THE MAIN ERROR CODES
#===============================================================================
# This section documents all error codes logged by the script.

# --- Startup & Environment Errors ---
# !F:1  - A required Perl module is missing.
# !F:3  - An invalid command-line argument was provided.
# !F:4  - The database connection test (-connect) failed.
# !F:5  - Could not write to the mode.cfg file to pause or resume processing.
# !F:20 - Failed to create both the primary working directory and the fallback directory.
# !F:21 - The primary working directory is not writable, and the config file is not readable.

# --- File Processing Errors ---
# !F:6  - A file took too long to process and exceeded the $max_exec_time limit.
# !F:7  - Could not extract the job number from the filename using the defined regex.
# !F:8  - The file does not have a valid .ps or .pdf extension.
# !F:9  - Failed to connect to the Informix database.
# !F:10 - Connected to the database but failed to execute the stored procedure.
# !F:11 - The stored procedure ran but returned no routing rule for the job number.
# !F:12 - Could not open or read the printer_manager.cfg configuration file.
# !F:13 - A rule was found in the database, but no matching rule for that file type exists in the config file.
# !F:31 - Invalid line format in printer_manager.cfg (not exactly 4 columns).

# --- Action & Movement Errors ---
# !F:14  - The destination directory does not exist and the script failed to create it.
# !F:14A - Created the destination directory but failed to set the correct permissions.
# !F:15  - Failed to move a file to its final destination directory.
# !F:16  - Failed to execute the system command to check for printers (e.g., lpstat -v).
# !F:17  - The printer name from the config file does not exist on the system.
# !F:18  - The system's print command (e.g., lp -d ...) failed.
# !F:25  - After a successful print job, failed to move the file to the 'processed' archive directory.
# !F:26  - After a successful print job, failed to delete the file (when archiving is disabled).
# !F:27  - Failed to move a file during the cleanup phase (from lost or stale directories).
# !F:28  - Failed to move an incoming file into the 'in_process' directory.
# !F:29  - Failed to read the mode.cfg file to check if the system is paused.
# !F:30  - System is paused, but failed to move the incoming file to the 'paused' directory.

# --- File Acquisition Errors ---
# !F:22 - A retry attempt to find an incoming file failed.
# !F:23 - Could not find an incoming file after all retry attempts were exhausted.

# --- Cleanup Phase Errors (Logged as failures but are informational) ---
# !F:19 - A "lost" file was found and moved to the 'unprocessed' directory for reprocessing.
# !F:24 - A "stale" file was found in the 'in_process' directory and moved to 'unprocessed'.

# --- Other Error Conditions ---
# Catastrophic Startup Failures:
#   If the script fails to set permissions on its own working directories, it will
#   'die' with a FATAL message directly to the console. These errors are considered
#   too severe for the standard logging system because they indicate a fundamental
#   environment or permissions problem.
#
# Non-Fatal Directory Warnings:
#   If a directory needed for cleanup or batch processing (like 'in_process' or
#   the '$recheck_original_dir') cannot be opened, the script will print a 'warn'
#   message to the console and skip that directory. This is treated as a non-fatal
#   operational issue, allowing the main script functions to continue.

#===============================================================================
#              PHASE 1: ENVIRONMENT SETUP (SELF-RE-EXECUTION)
#===============================================================================
# This block ensures the Informix environment is correctly set before any
# database modules are loaded. It is the first code to execute.

unless ($ENV{PERL_ENV_IS_CONFIGURED}) {
    $ENV{PERL_ENV_IS_CONFIGURED} = 1;

    # Set all required Informix environment variables.
    $ENV{'INFORMIXDIR'}      = $informix_dir;
    $ENV{'INFORMIXSERVER'}   = $informix_server;
    $ENV{'INFORMIXSQLHOSTS'} = $informix_sqlhosts;
    $ENV{'ONCONFIG'}         = $informix_onconfig;

    # Prepend Informix library paths to LD_LIBRARY_PATH.
    $ENV{'LD_LIBRARY_PATH'} = $informix_libs . (defined $ENV{'LD_LIBRARY_PATH'} ? ":$ENV{'LD_LIBRARY_PATH'}" : '');

    # Re-execute the script. The new process inherits the correct environment.
    exec($^X, $0, @ARGV) or die "FATAL: Failed to re-execute script to set environment: $!";
}

# If we've reached this point, the environment is correctly configured.
# We can now safely load the database drivers and other modules.
use strict;
use warnings;
use DBI;
use File::Copy qw(move);
use File::Basename qw(basename);
use Fcntl ':flock';
use File::Path qw(make_path rmtree);
use English qw( -no_match_vars );

#===============================================================================
#             MAIN SCRIPT LOGIC
#===============================================================================

# --- Global variables that will be defined by setup_directories() ---
my ($success_log, $failure_log, $verbose_log, $in_process_dir, $unprocessed_dir, 
    $processed_dir, $paused_dir, $mode_file);

# --- Global variable for the database handle ---
my $dbh;

#===============================================================================
#                             SUBROUTINES
#===============================================================================

#
# setup_directories - Initializes the script's directory structure.
#
# This subroutine is the primary setup function for all file-system operations.
# It checks for the existence and writability of the main working directory,
# creates it and its subdirectories if they don't exist, and sets the global
# path variables used throughout the rest of the script. It also handles the
# fallback logic to use a /tmp/ directory if the primary one is unusable.
#
sub setup_directories {
    # --- PHASE 0: INITIAL STARTUP AND STRUCTURE VERIFICATION ---
    my $base_dir = $working_directory; # Start with the configured directory

    if (! -d $base_dir) {
        # 0.1: Directory does not exist, attempt to create it.
        unless (make_path($base_dir, { error => \my $err })) {
            # Creation failed, enter fallback mode.
            $base_dir = '/tmp/printer_manager_fallback';
            print STDERR "WARNING: Could not create working directory '$working_directory'. Using fallback '$base_dir'. Error: $err->[0]{message}\n";
            unless (make_path($base_dir, { error => \$err })) {
                die "FATAL (!F:20): Could not create primary or fallback working directory. Error: $err->[0]{message}\n";
            }
        }
        # Explicitly set permissions to override umask.
        chmod($DIR_PERMISSIONS, $base_dir) or die "FATAL: Could not set permissions on '$base_dir': $OS_ERROR";
    } elsif (! -w $base_dir) {
        # 0.2: Directory exists but is not writable, enter hybrid fallback mode.
        if (! -r $config_file) {
            # Cannot read config file, this is a fatal error.
            my $fallback_log_path = "/tmp/printer_manager_fallback/printer_manager_failures.log";
            make_path('/tmp/printer_manager_fallback');
            chmod($DIR_PERMISSIONS, '/tmp/printer_manager_fallback');
            open(my $fh, '>>', $fallback_log_path) or die "FATAL (!F:21): Cannot write to primary working directory AND cannot read config file '$config_file'. Also failed to open fallback log '$fallback_log_path': $!";
            print $fh "FATAL (!F:21): Working directory '$working_directory' is not writable and config file '$config_file' is not readable.\n";
            close $fh;
            exit 1;
        }
        # Can read config, but all other paths must go to fallback.
        $base_dir = '/tmp/printer_manager_fallback';
        print STDERR "WARNING: Working directory '$working_directory' is not writable. Using fallback '$base_dir' for logs and subdirectories.\n";
        make_path($base_dir) unless -d $base_dir;
        chmod($DIR_PERMISSIONS, $base_dir) or die "FATAL: Could not set permissions on fallback dir '$base_dir': $OS_ERROR";
    }

    # 0.3: Establish final derived paths
    $success_log     = "$base_dir/printer_manager.log";
    $failure_log     = "$base_dir/printer_manager_failures.log";
    $verbose_log     = "$base_dir/printer_manager_verbose.log";
    $in_process_dir  = "$base_dir/in_process";
    $unprocessed_dir = "$base_dir/unprocessed";
    $processed_dir   = "$base_dir/processed";
    $paused_dir      = "$base_dir/paused";
    $mode_file       = "$base_dir/mode.cfg";

    # Create all necessary subdirectories and set their permissions explicitly.
    # This only sets permissions on directories it creates itself.
    foreach my $dir ($in_process_dir, $unprocessed_dir, $processed_dir, $paused_dir) {
        unless (-d $dir) {
            make_path($dir, { verbose => 0 }) or die "FATAL: Could not create directory '$dir': $OS_ERROR";
            chmod($DIR_PERMISSIONS, $dir) or die "FATAL: Could not set permissions on '$dir': $OS_ERROR";
        }
    }
}

#
# check_dependencies - Verifies that all required Perl modules are installed.
#
# This is a startup check that runs only in '-connect' mode. It iterates through
# a list of essential modules and uses `eval "require ..."` to see if they can be
# loaded. If any module is missing, it terminates the script with a fatal error
# message, preventing runtime failures later.
#
sub check_dependencies {
    my @modules = qw(DBI File::Copy File::Basename Fcntl File::Path English);
    print "Checking for required Perl modules...\n";
    foreach my $module (@modules) {
        eval "require $module";
        if ($@) {
            # This is a startup failure, so we die directly to the console.
            die "FATAL (!F:1): Required Perl module '$module' is not installed. Please install it and try again.\n";
        }
    }
    print "All required modules are present.\n";
}

#
# get_timestamp - Returns a consistently formatted timestamp string.
#
sub get_timestamp {
    my ($sec, $min, $hour, $mday, $mon, $year) = localtime();
    return sprintf("%04d-%02d-%02d|%02d:%02d:%02d", $year+1900, $mon+1, $mday, $hour, $min, $sec);
}

#
# log_to_file - A generic, safe file-writing subroutine for all logs.
# @param $log_path      - The primary path for the log file.
# @param $fallback_path - A secondary path to use if the primary is unwritable.
# @param $entry         - The string to be written to the log file.
#
# This function handles opening, locking, writing, and closing log files. It also
# sets the file permissions on newly created log files.
#
sub log_to_file {
    my ($log_path, $fallback_path, $entry) = @_;
    my $log_fh;
    my $file_exists = -e $log_path;
    unless(open($log_fh, '>>', $log_path)) {
        $file_exists = -e $fallback_path;
        unless(open($log_fh, '>>', $fallback_path)) {
            warn "CRITICAL: Could not write to primary or fallback log: $entry\n";
            return;
        }
        chmod($FILE_PERMISSIONS, $fallback_path) unless $file_exists;
    }
    chmod($FILE_PERMISSIONS, $log_path) unless $file_exists;

    flock($log_fh, LOCK_EX);
    print $log_fh "$entry\n";
    flock($log_fh, LOCK_UN);
    close $log_fh;
}

#
# log_verbose - Writes a message to the verbose log if enabled.
#
sub log_verbose {
    my ($message) = @_;
    return unless $verbose_logging;
    my $timestamp = get_timestamp();
    my $log_entry = "$timestamp|$message";
    log_to_file($verbose_log, "/tmp/printer_manager_fallback/printer_manager_verbose.log", $log_entry);
}

#
# log_failure - Writes a formatted error message to the failure log.
#
sub log_failure {
    my ($filename, $error_code, $message) = @_;
    my $timestamp = get_timestamp();
    my $log_entry = join('|', $timestamp, $filename // 'N/A', $error_code, $message);
    log_to_file($failure_log, "/tmp/printer_manager_fallback/printer_manager_failures.log", $log_entry);
}

#
# log_success - Writes a formatted success message to the main log.
#
sub log_success {
    my ($filename, $status, $action, $destination) = @_;
    my $timestamp = get_timestamp();
    my $log_entry = join('|', $timestamp, $filename, $status, $action, $destination);
    log_to_file($success_log, "/tmp/printer_manager_fallback/printer_manager.log", $log_entry);
}

#
# lme - The primary error handling routine: Log, Move, and End.
#
# This subroutine is called for any fatal processing error. It logs the failure,
# moves the problematic file to the 'unprocessed' directory for later inspection,
# and then terminates the current operation by calling `die`. The `die` allows the
# error to be caught in batch modes, preventing one bad file from stopping the whole run.
#
sub lme { # Log, Move, and End (by dying)
    my ($file_path, $error_code, $error_message, $status_for_log) = @_;
    my $filename = basename($file_path // 'N/A');
    log_failure($filename, $error_code, $error_message);
    
    # Specific logging for reprocessing failures
    if ($status_for_log && $status_for_log eq 'REPROCESSED_FAIL') {
        log_success($filename, 'REPROCESSED_FAIL', 'N/A', 'N/A');
    }

    if ($file_path && -f $file_path) {
        move($file_path, $unprocessed_dir) or
            log_failure($filename, "!F:27", "Could not move file to unprocessed dir: $OS_ERROR");
    }
    if ($dbh) {
        $dbh->disconnect;
    }
    # Use die to allow the error to be trapped by eval in batch processing modes.
    # For single-file mode, this will still terminate the script as intended.
    die "LME Handled Error: $error_code";
}

#
# execute_directory_move - Handles the logic for moving a file to a destination directory.
#
sub execute_directory_move {
    my ($current_file_path, $destination_dir, $status_for_log) = @_;
    my $original_filename = basename($current_file_path);

    log_verbose("Action: MOVE. Destination: '$destination_dir'");
    # If the destination directory does not exist, try to create it.
    unless (-d $destination_dir) {
        log_verbose("Destination directory does not exist. Attempting to create it.");
        unless (make_path($destination_dir, { error => \my $err })) {
            my $error_message = "Failed to create destination directory path for '$destination_dir': " . $err->[0]{message};
            lme($current_file_path, '!F:14', $error_message, $status_for_log);
        }
        unless (chmod($DIR_PERMISSIONS, $destination_dir)) {
             my $error_message = "Failed to set permissions on created directory '$destination_dir': $OS_ERROR";
             rmtree($destination_dir);
             lme($current_file_path, '!F:14A', $error_message, $status_for_log);
        }
    }
    
    my $final_path = "$destination_dir/$original_filename";
    if (move($current_file_path, $final_path)) {
        log_success($original_filename, $status_for_log, 'MOVE', $destination_dir);
        log_verbose("Successfully moved file to '$final_path'.");
    } else {
        lme($current_file_path, '!F:15', "Failed to move file to '$destination_dir': $OS_ERROR", $status_for_log);
    }
}

#
# execute_print_action - Handles the logic for sending a file to a system printer.
#
sub execute_print_action {
    my ($current_file_path, $printer_name, $status_for_log) = @_;
    my $original_filename = basename($current_file_path);

    log_verbose("Action: PRINT. Destination: '$printer_name'");
    open(my $pipe, '-|', $printer_check_command) or lme($current_file_path, '!F:16', "Could not execute printer check command '$printer_check_command': $OS_ERROR", $status_for_log);
    my $printer_list = do { local $/; <$pipe> };
    close $pipe;

    unless ($printer_list =~ /\Q$printer_name\E/) {
        lme($current_file_path, '!F:17', "Printer '$printer_name' not found in system printer list.", $status_for_log);
    }
    log_verbose("Printer '$printer_name' found in system list.");

    my $print_cmd = $command_for_printing;
    $print_cmd =~ s/<printer_name>/$printer_name/g;
    $print_cmd =~ s/<file_path>/$current_file_path/g;
    
    my @cmd_parts = split /\s+/, $print_cmd;
    
    log_verbose("Executing print command: '" . join(' ', @cmd_parts) . "'");
    my $exit_code = system(@cmd_parts);
    if ($exit_code != 0) {
        lme($current_file_path, '!F:18', "Print command failed for printer '$printer_name' with exit code: " . ($exit_code >> 8), $status_for_log);
    }

    log_success($original_filename, $status_for_log, 'PRINT', $printer_name);
    log_verbose("Print command executed successfully.");

    if ($save_processed_files) {
        log_verbose("Archiving file to processed directory.");
        move($current_file_path, "$processed_dir/$original_filename") or
            log_failure($original_filename, '!F:25', "Could not archive printed file to processed dir: $OS_ERROR");
    } else {
        log_verbose("Deleting file after printing.");
        unlink($current_file_path) or
            log_failure($original_filename, '!F:26', "Could not delete printed file: $OS_ERROR");
    }
}


#
# main_processing_workflow - The core logic for processing a single file.
#
# This subroutine orchestrates the entire process for one file: it sets a timeout,
# extracts the job number and format, queries the database, finds the matching rule
# in the config file, and then calls the appropriate action subroutine (move or print).
#
sub main_processing_workflow {
    my ($current_file_path, $status_on_success) = @_;
    $status_on_success //= 'PROCESSED'; # Default status
    my $status_on_failure = ($status_on_success eq 'REPROCESSED_OK') ? 'REPROCESSED_FAIL' : undef;

    my $original_filename = basename($current_file_path);
    log_verbose("Starting main processing workflow for '$original_filename'.");

    eval {
        local $SIG{ALRM} = sub { die "Timeout\n" };
        alarm($max_exec_time) if $max_exec_time > 0;
        log_verbose("Execution timeout alarm set for $max_exec_time seconds.");

        my ($job_number) = $original_filename =~ $job_regex_pattern;
        lme($current_file_path, '!F:7', "Invalid regex pattern for job_number on file '$original_filename'", $status_on_failure) unless $job_number;
        log_verbose("Extracted job number: $job_number");

        my ($user_name) = $original_filename =~ $user_name_regex;
        log_verbose("Extracted user name: " . ($user_name // 'N/A'));

        my ($file_format) = $original_filename =~ /\.(ps|pdf)$/i;
        lme($current_file_path, '!F:8', "File '$original_filename' does not have a valid .ps or .pdf extension.", $status_on_failure) unless $file_format;
        $file_format = lc($file_format);
        log_verbose("Extracted file format: $file_format");

        my $ifx_name_set;
        eval {
            log_verbose("Connecting to database '$db_name'...");
            $dbh = DBI->connect("dbi:Informix:$db_name", $db_user, $db_password, { RaiseError => 1, PrintError => 0 });
            my $sql = $ifx_procedure;
            $sql =~ s/<job_number>/$job_number/;
            log_verbose("Executing procedure: $sql");
            my $sth = $dbh->prepare($sql);
            $sth->execute();
            ($ifx_name_set) = $sth->fetchrow_array();
            $sth->finish();
            $dbh->disconnect();
            $dbh = undef;
            log_verbose("Database operation successful.");
        };
        if ($EVAL_ERROR) {
            my $err_code = ($EVAL_ERROR =~ /connect/) ? '!F:9' : '!F:10';
            lme($current_file_path, $err_code, "DB function failed: $EVAL_ERROR", $status_on_failure);
        }
        lme($current_file_path, '!F:11', "Job '$job_number' name set not found in db", $status_on_failure) unless (defined $ifx_name_set && $ifx_name_set ne '');
        $ifx_name_set =~ s/^\s+|\s+$//g;
        log_verbose("Retrieved name set from database: '$ifx_name_set'");

        my $specific_user_rule;
        my $default_user_rule;
        log_verbose("Reading config file '$config_file' to find match...");
        open(my $cfg_fh, '<', $config_file) or lme($current_file_path, '!F:12', "Could not open configuration file '$config_file': $OS_ERROR", $status_on_failure);
        
        while (my $line = <$cfg_fh>) {
            next if $line =~ /^\s*#/ or $line =~ /^\s*$/;
            chomp $line;
            
            my @columns = split(/\|/, $line);
            if (@columns != 4) {
                log_failure($original_filename, '!F:31', "Invalid line format in config file (line $.) - expected 4 columns, found " . scalar(@columns) . ": \"$line\"");
                next; # Skip this invalid line
            }

            my ($cfg_name_set, $cfg_user, $cfg_format, $cfg_rule) = @columns;
            
            # Trim whitespace from all columns
            foreach my $col ($cfg_name_set, $cfg_user, $cfg_format, $cfg_rule) {
                $col =~ s/^\s+|\s+$//g;
            }

            # Check for a match on name set and format (case-insensitive)
            if (lc($cfg_name_set) eq lc($ifx_name_set) && lc($cfg_format) eq lc($file_format)) {
                # Check for a specific user match (case-insensitive)
                if (defined $user_name && lc($cfg_user) eq lc($user_name)) {
                    $specific_user_rule = $cfg_rule;
                    log_verbose("Found specific user rule on line $.: '$cfg_rule'");
                    last; # A specific user match is the highest priority, so we can stop looking.
                }
                # Check for a DEFAULT rule
                elsif (lc($cfg_user) eq 'default') {
                    $default_user_rule = $cfg_rule;
                    log_verbose("Found DEFAULT user rule on line $.: '$cfg_rule'");
                }
            }
        }
        close $cfg_fh;

        my $printer_dir_rule = $specific_user_rule // $default_user_rule;

        lme($current_file_path, '!F:13', "Job '$job_number' found but no matching rule for user '".($user_name // 'N/A')."' or DEFAULT was found in config file for format '$file_format'", $status_on_failure) unless $printer_dir_rule;
        log_verbose("Final matching rule selected: '$printer_dir_rule'");

        if ($printer_dir_rule =~ m{^/}) {
            execute_directory_move($current_file_path, $printer_dir_rule, $status_on_success);
        } else {
            execute_print_action($current_file_path, $printer_dir_rule, $status_on_success);
        }
        
        alarm(0);
    };
    if ($EVAL_ERROR) {
        if ($EVAL_ERROR =~ /Timeout/) {
            lme($current_file_path, '!F:6', "Processing timed out after $max_exec_time seconds.", $status_on_failure);
        } else {
            # Re-throw other critical errors so they can be caught by the caller
            die $EVAL_ERROR;
        }
    }
}

#
# process_directory - Iterates through a directory and processes each file found.
#
sub process_directory {
    my ($dir, $status_for_log) = @_;
    opendir(my $dh, $dir) or do {
        warn "Could not open directory '$dir': $OS_ERROR";
        return;
    };
    my @files = grep { !/^\./ && -f "$dir/$_" } readdir($dh);
    closedir($dh);

    print "Found " . scalar(@files) . " file(s) to process in '$dir'.\n";
    foreach my $file (@files) {
        my $full_path = "$dir/$file";
        print "Processing '$file'...\n";
        
        # In batch mode, we move the file to in_process first
        my $in_process_file_path = "$in_process_dir/" . basename($full_path);
        unless(move($full_path, $in_process_file_path)) {
            log_failure(basename($full_path), '!F:28', "Could not move file to in_process directory: $OS_ERROR");
            print "--> Error moving '$file' to in_process. Skipping.\n";
            next;
        }

        eval {
            main_processing_workflow($in_process_file_path, $status_for_log);
        };
        if ($EVAL_ERROR) {
            # LME already logged the detailed error to the failure log.
            # This is just a console notification that we are skipping this file and continuing.
            print "--> Error processing '$file'. See failure log for details. Continuing to next file.\n";
        }
    }
    print "Finished processing all files in '$dir'.\n";
}

#
# run_cleanup_phase - Scans for and handles "lost" and "stale" files.
#
# This subroutine performs two main tasks:
# 1. Checks the '$recheck_original_dir' for files older than '$recheck_original_dir_file_age'.
# 2. Checks the '$in_process_dir' for files older than '$stale_file_age_limit_seconds'.
# Any files found are moved to the 'unprocessed' directory for later reprocessing.
#
sub run_cleanup_phase {
    log_verbose("Starting cleanup phase.");
    # --- 8.2 Lost Files Cleanup ---
    if ($recheck_original_dir && $recheck_original_dir ne '') {
        if (-d $recheck_original_dir) {
            log_verbose("Scanning for lost files in '$recheck_original_dir' older than $recheck_original_dir_file_age seconds.");
            opendir(my $dh, $recheck_original_dir) or do {
                warn "Could not open directory '$recheck_original_dir' for cleanup: $OS_ERROR";
                return;
            };
            my @files = grep { /\.(ps|pdf)$/i && -f "$recheck_original_dir/$_" } readdir($dh);
            closedir($dh);

            my $now = time();
            foreach my $file (@files) {
                my $full_path = "$recheck_original_dir/$file";
                my $mtime = (stat($full_path))[9];
                if (($now - $mtime) > $recheck_original_dir_file_age) {
                    if (move($full_path, "$unprocessed_dir/$file")) {
                        log_failure($file, '!F:19', "File moved from lost+found ('$recheck_original_dir') to unprocessed due to age.");
                        log_verbose("Moved lost file '$file' to unprocessed.");
                    } else {
                        log_failure($file, '!F:27', "Failed to move old file from '$recheck_original_dir': $OS_ERROR");
                    }
                }
            }
        }
    }

    # --- 8.3 Stale Files Cleanup ---
    if (-d $in_process_dir) {
        log_verbose("Scanning for stale files in '$in_process_dir' older than $stale_file_age_limit_seconds seconds.");
        opendir(my $dh, $in_process_dir) or do {
            warn "Could not open directory '$in_process_dir' for cleanup: $OS_ERROR";
            return;
        };
        my @files = grep { !/^\./ && -f "$in_process_dir/$_" } readdir($dh);
        closedir($dh);

        my $now = time();
        foreach my $file (@files) {
            my $full_path = "$in_process_dir/$file";
            my $mtime = (stat($full_path))[9];
            if (($now - $mtime) > $stale_file_age_limit_seconds) {
                if (move($full_path, "$unprocessed_dir/$file")) {
                    log_failure($file, '!F:24', "File moved from in_process to unprocessed due to being stale.");
                    log_verbose("Moved stale file '$file' to unprocessed.");
                } else {
                    log_failure($file, '!F:27', "Failed to move stale file from '$in_process_dir': $OS_ERROR");
                }
            }
        }
    }
    log_verbose("Cleanup phase finished.");
}

#
# display_help - Prints the help text to the console.
#
sub display_help {
    print <<'END_HELP';
 ----------------------------------------------------------------------------   
    printer_manager.pl - Manages file routing based on database rules.

USAGE:
    printer_manager.pl <command>

COMMANDS:
    <file_path>
        Standard processing mode. Takes a full path to a .ps or .pdf file,
        queries the database for a routing rule, and moves or prints the file.
        This is the primary operational mode.

    -connect
        A diagnostic mode to test the connection to the Informix database.
        Also checks for required Perl modules. Reports success or failure.

    -pause
        Pauses the processing of new incoming files. Any new files received
        will be moved to the 'paused' directory for later processing.

    -resume
        Resumes normal operation. Sets the system status to 'online' and
        processes all files currently in the 'paused' directory.

    -redo
        Re-processes files that have previously failed. It first finds any
        "lost" or "stale" files and then processes the entire contents of
        the 'unprocessed' directory.

    -help
        Displays this help message and exits.

END_HELP
}

#===============================================================================
#                      PROGRAM EXECUTION START
#===============================================================================

#
# Main execution block. The script's behavior is determined by the single
# command-line argument it receives.
#

if (@ARGV != 1) {
	display_help();
	exit 1;
}

my $mode = $ARGV[0];

# --- Handle modes that DO NOT require directory setup first ---
if ($mode eq '-connect') {
    check_dependencies();
	print "Attempting to connect to database '$db_name' on server '$ENV{INFORMIXSERVER}'...\n";
	my $dsn = "dbi:Informix:$db_name";
	my $connection_test_result;
	eval {
		my $dbh = DBI->connect($dsn, $db_user, $db_password, { RaiseError => 1, PrintError => 0 });
		my $sth = $dbh->prepare("SELECT CURRENT :: DATETIME YEAR TO SECOND AS date_time FROM sysmaster:sysdual");
		$sth->execute();
		($connection_test_result) = $sth->fetchrow_array();
		$sth->finish();
		$dbh->disconnect();
	};
	if ($EVAL_ERROR) {
        # No need to call setup_directories for logging, just die.
		die "FATAL (!F:4): Connection test FAILED. Error: $EVAL_ERROR\n";
	}
	print "Connection test succeeded, system current date time: \"$connection_test_result\"\n";
}
elsif ($mode eq '-help') {
    display_help();
}
elsif ($mode !~ /^-/ || $mode eq '-pause' || $mode eq '-resume' || $mode eq '-redo') {
    # --- Handle all modes that DO require directory setup ---
    setup_directories();

    if ($mode eq '-pause') {
        log_verbose("Mode: -pause");
        open(my $fh, '>', $mode_file) or die "FATAL (!F:5): Could not write to mode file '$mode_file': $OS_ERROR";
        print $fh "paused";
        close $fh;
        chmod($FILE_PERMISSIONS, $mode_file);
        print "Processing has been PAUSED. New files will be queued.\n";
    }
    elsif ($mode eq '-resume') {
        log_verbose("Mode: -resume");
        open(my $fh, '>', $mode_file) or die "FATAL (!F:5): Could not write to mode file '$mode_file': $OS_ERROR";
        print $fh "online";
        close $fh;
        chmod($FILE_PERMISSIONS, $mode_file);
        print "Processing has been RESUMED.\n";
        process_directory($paused_dir, 'PROCESSED');
    }
    elsif ($mode eq '-redo') {
        log_verbose("Mode: -redo");
        # First, find any "lost" or "stale" files and move them to unprocessed so they can be included in the batch.
        print "Checking for lost and stale files before reprocessing...\n";
        run_cleanup_phase();

        # Now, process the main unprocessed directory which may contain newly moved files.
        print "Starting reprocessing of files from '$unprocessed_dir'.\n";
        process_directory($unprocessed_dir, 'REPROCESSED_OK');
    }
    else { # This is the standard <file_path> mode
        log_verbose("Mode: <file_path> received '$mode'");
        # This block now uses an eval to ensure the cleanup phase always runs.
        eval {
            my $incoming_file_path = $ARGV[0];

            # --- File Acquisition ---
            my $file_found = 0;
            log_verbose("Waiting $wait_before_1st_try second(s) before first file check...");
            sleep($wait_before_1st_try);
            for my $attempt (0 .. $max_times_to_retry) {
                if (-f $incoming_file_path) {
                    $file_found = 1;
                    log_verbose("Found file on attempt " . ($attempt + 1) . ".");
                    last;
                }
                if ($max_times_to_retry > 0 && $attempt < $max_times_to_retry) {
                    my $attempt_num = $attempt + 1;
                    log_failure(basename($incoming_file_path), '!F:22', "File not found, attempt $attempt_num/$max_times_to_retry, retrying in $seconds_between_retries s.");
                    log_verbose("File not found on attempt $attempt_num. Retrying in $seconds_between_retries seconds...");
                    sleep($seconds_between_retries);
                }
            }

            unless ($file_found) {
                log_failure(basename($incoming_file_path), '!F:23', "File not found after all attempts.");
                die "Exiting due to F23.";
            }

            # --- Secure the file by moving it to in_process immediately ---
            my $original_filename = basename($incoming_file_path);
            my $in_process_file_path = "$in_process_dir/$original_filename";
            log_verbose("Moving file to in_process directory: '$in_process_file_path'");
            move($incoming_file_path, $in_process_file_path) 
                or lme($incoming_file_path, '!F:28', "Could not move file to in_process directory: $OS_ERROR");

            # --- Check for Paused Mode ---
            if (-f $mode_file) {
                open(my $fh, '<', $mode_file) or lme($in_process_file_path, '!F:29', "Could not read mode file '$mode_file': $OS_ERROR");
                my $status = <$fh>;
                close $fh;
                if ($status && $status =~ /paused/) {
                    log_verbose("System is PAUSED. Moving file to paused directory.");
                    my $dest_path = "$paused_dir/$original_filename";
                    move($in_process_file_path, $dest_path) or lme($in_process_file_path, '!F:30', "Could not move file to paused dir: $OS_ERROR");
                    log_success($original_filename, 'PAUSED', 'N/A', $paused_dir);
                    print "System is paused. File queued to '$paused_dir'.\n";
                    # We exit cleanly here, but the END block will still run the cleanup.
                    exit 0;
                }
            }
            log_verbose("System is online. Proceeding with main workflow.");

            # --- Start the main workflow ---
            main_processing_workflow($in_process_file_path, 'PROCESSED');
        };
        if ($EVAL_ERROR) {
            # This catches errors from lme() or other die() calls.
            # The error has already been logged by lme(). We just need to prevent the script from exiting with a non-zero status here.
            log_verbose("Caught a fatal error during standard processing. Error: $EVAL_ERROR");
        }
        
        # --- PHASE 8: LOST AND STALE FILE CLEANUP ---
        # This runs at the end of a standard file processing run, regardless of success or failure.
        run_cleanup_phase();
    }
}
else {
    # This is for any invalid command-line argument, like "-foobar"
    # No need to call setup_directories for this, as it doesn't log to a file.
	print "Error: Mode '$mode' is not a valid option.\n";
    display_help();
	exit 1;
}
exit 0;