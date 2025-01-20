<#
Filename: PSCallGraph.ps1
Purpose: To read a powershell script and create a call graph with mermaid for functions defined within the file
Written By: Kelvin Smith - 2024
Version: 1.0

Parameters:
 - scriptFile - Name and path to the source file - can pass multiple files in using a comma to separate
 - outputFile - Name and path of the mermaid diagram
#>
[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true,
        ParameterSetName = 'Local')]
    [string[]]$scriptFile,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile = (Get-Location).Path

)


function Write-Log {
<#
	.SYNOPSIS
		Writes a log entry to the console including severity and timetime

	.DESCRIPTION
		This function is used to display a log message.  The format is "timestamp [severity] message".  The message is written to the console

	.PARAMETER message
		The message to be displayed

	.PARAMETER severity
		The severity of the message.  Options are INFO, VERBOSE, WARNING or ERROR

    .PARAMETER timestamp
        Optional timestamp value.  If omitted uses the current time

	.EXAMPLE
		write-log -message "This is an info line" -severity INFO
#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [ValidateSet("INFO", "VERBOSE", "WARNING", "ERROR")]
        [string]$Severity,

        [Parameter()]
        [datetime]$Timestamp = (Get-Date)
    )

    # Format the log entry
    $logEntry = "{0} [{1}] {2}" -f $Timestamp.ToString("dd-MM-yyyy HH:mm:ss"), $Severity, $Message

    switch ($severity) {

        VERBOSE { write-verbose $logEntry }
        default { Write-Information $logEntry }
    }
}



function Get-ResolvePath {
<#
	.SYNOPSIS
		Creates a path relative to the source if a fixed path is not given for the destination

	.DESCRIPTION
		This function is used to return the path of a file.  If a relative is provided for the destination, then
		this is worked out using the source path as the base path.  This is used to calculate paths that are relative
		to the source directory.  If the destination path is fixed (fully qualified), then we ignore the source path
		and just return the destination value

	.PARAMETER sourcePath
		The base path that is used for any relative path of destination

	.PARAMETER destPath
		The desired destination path, either relative to sourcePath or fully qualified

	.EXAMPLE
		Get-Resolvepath -sourcePath "C:\temp" -destPath 'output\logs.txt'

	.INPUTS
		Both parameters are Strings

	.OUTPUTS
		String
#>
	[CmdletBinding()]
	PARAM(
		[Parameter(Mandatory)]
		[string] $sourcePath,
		[Parameter(Mandatory)]
		[string] $destPath
	)
	
	# If we are provided a fixed path, then the source path does not matter
	if ([System.IO.Path]::IsPathRooted($destPath)) {
		return $destPath
	}

	# .. Otherwise return the source joined with the destination path
	return Join-Path -Path (Split-Path -path $sourcePath) -ChildPath $destPath
}

function Find-CallGraphPhase1 {
<#
	.SYNOPSIS
		Parses .ps1 files and generates a list of functions defined

	.DESCRIPTION
		This function reads the supplied file and parses it to find any functions that are defined within the file.  If the file dot sources another file, it is parsed as well.  This function
        is recursive.

	.PARAMETER $file
		The file to be parsed

	.PARAMETER $callGraphArray
		A hash table array where the function names are created

	.EXAMPLE
        $myCallGraph = @{}
		Find-CallGraphPhase1 -file "C:\temp\test.ps1" -callGraphArray $myCallGraph

	.INPUTS
		file is path to the powershell file
        CallGraphArray is a hashtable

	.OUTPUTS
		Hashtable, with the functions found appended.
#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string] $file,
        [Parameter(Mandatory)]
        [hashtable] $callGraphArray
)


	# Parse 1 - Find all the functions
	# Read the script file line by line

	write-Log -Message "===== Parse 1 - Find functions =====" -Severity INFO

    # Use a LIFO stack for current function
    $callStack = New-Object System.Collections.Stack
    $callStack.push('main')

    # If there is no 'main' defined, then do it
    if (!$callGraphArray.ContainsKey('main')) {
        $callGraphArray['main'] = @()
    }

    # True if we have found a dot source operator so we can capture the path/file
    $foundIncludeOperator = $false

	write-Log -Message "Reading file $file" -Severity INFO
	if (Test-Path -Path $file) {
		$scriptContent = (Get-Content -Path $file -Raw)
	} else {
		write-Log -Message "Unable to find file: $file" -Severity ERROR
		return	
	}

	# Convert the file into tokens for processing
	$Tokens = [System.Management.Automation.PSParser]::Tokenize($scriptContent, [Ref] $Null) | Where-Object { $_.Type -ne 'Comment' }

	# This tracks if we have found a function keyword as we need the next token that defines the function name
	$foundFunction = $false
	foreach ($token in $Tokens)
	{
		# We are interested in the Type = function, then capture the command argument after it
		if (($token.Type -eq 'Keyword') -and ( $token.Content -eq 'function')) {
			$foundFunction = $true
			continue
		}
		if ($foundFunction) {
			$foundFunction = $false
			# As function names are case insenstive, we convert to lower case as mermaid is case sensitive
			$functionName = ($token.Content).ToLower()
			# Add it to the array
			$callGraphArray[$functionName] = @()
			write-Log -Message "Line $($token.StartLine) - Found function: '$functionName'" -Severity VERBOSE
		}
		# If there is a . operator by itself, it may be an include operation so flag for next token
		if ($token.Type -eq 'Operator' -and $token.Content -eq '.') {
				$foundIncludeOperator = $true
				continue
		}
		# If we are signaling an include operator, and this token is a command, parse the file
		if ($foundIncludeOperator) {
			if ($token.Type -eq 'Command') {
					Write-Log -Message "Found included file $($token.Content) - Disposing" -Severity VERBOSE
                    $callGraphArray = (Find-CallGraphPhase1 -file ( Get-ResolvePath -sourcePath $file -destPath $token.Content) -callGraphArray $callGraphArray)
					Write-Log -Message "Finished Disposing file $($token.Content)" -Severity VERBOSE
			}
			$foundIncludeOperator = $false
		}
	}
    $callGraphArray
}

function Find-CallGraphPhase2 {
<#
	.SYNOPSIS
		Parses .ps1 files and adds to the call out of functions to the array

	.DESCRIPTION
		This function reads the supplied file and parses it to find any of the functions found during the first pass being called.  For any that are found, the function that calls it is
        stored.

	.PARAMETER $file
		The file to be parsed

	.PARAMETER $callGraphArray
		A hash table array where the function names found during pass one is stored

	.EXAMPLE
        $myCallGraph = @{}
        $myCallGraph = Find-CallGraphPhase2 -file "C:\temp\temp.ps1" -callGraphArray $myCallGraph
		Find-CallGraphPhase2 -file "C:\temp\test.ps1" -callGraphArray $myCallGraph

	.INPUTS
		file is path to the powershell file
        CallGraphArray is a hashtable

	.OUTPUTS
		Hashtable, with the functions found appended.
#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string] $file,
        [Parameter(Mandatory)]
        [hashtable] $callGraphArray
)

	write-Log -Message "===== Parse 2 - Find Calling Functions =====" -Severity INFO

    # Use a LIFO stack for current function
    $callStack = New-Object System.Collections.Stack
    $callStack.push('main')

	write-Log -Message "Reading file $file" -Severity INFO
	if (Test-Path -Path $file) {
		$scriptContent = (Get-Content -Path $file -Raw)
	} else {
		write-Log -Message "Unable to find file: $file" -Severity ERROR
		return
	}

	# Convert the file into tokens for processing
	$Tokens = [System.Management.Automation.PSParser]::Tokenize($scriptContent, [Ref] $Null) | Where-Object { $_.Type -ne 'Comment' }

	# Set variables
	# This variable tracks how many depths of { we are.  When we return to 0 then we have finished a function
	$countDepth = 0

	# If we have found a function keyword, then the next token is the function name
	$foundFunction = $false

	# This is used to determine if the next token is a filename when dot sourced
	$foundIncludeOperator = $false

	# Iterate over all tokens
	foreach ($token in $Tokens) {

		# We are interested in the Type = function, then capture the command argument after it
		if (($token.Type -eq 'Keyword') -and ( $token.Content -eq 'function')) {
			$foundFunction = $true
			continue
		}
		# Record the name of the function
		if ($foundFunction) {
			# Add the name to the stack as we can have functions nested in functions.
			$callStack.push( ($token.Content).ToLower())
			$foundFunction = $false
			write-Log -Message "Line $($token.StartLine) - Found function: '$($callstack.peek())'" -Severity VERBOSE
			continue
		}
		# If there is a . operator by itself, it may be an include operation so flag for next token
		if ($token.Type -eq 'Operator' -and $token.Content -eq '.') {
				$foundIncludeOperator = $true
				continue
		}
		# If we are signaling an include operator, and this token is a command, parse the file
		if ($foundIncludeOperator) {
			if ($token.Type -eq 'Command') {
					Write-Log -Message "Found included file $($token.Content) - Disposing" -Severity VERBOSE
                    $callGraphArray = (Find-CallGraphPhase2 -file ( Get-ResolvePath -sourcePath $file -destPath $token.Content) -callGraphArray $callGraphArray)
					Write-Log "Finished Disposing file $($token.Content)" -severity VERBOSE
			}
			$foundIncludeOperator = $false
			continue
		}
		# Track what depth we are in
		if ($token.Type -eq 'GroupStart' -and ($token.Content -eq '{' -or $token.Content -eq '@{')) {
			$countDepth++
#			write-Log -Message "Line $($token.StartLine) - GroupDepth is $countDepth" -Severity VERBOSE
			continue
		}
		# If we return to depth 0, then we have exited the function
		if ($token.Type -eq 'GroupEnd' -and $token.Content -eq '}') {
			$countDepth--
#			write-Log -Message "Line $($token.StartLine) - GroupDepth is $countDepth" -Severity VERBOSE
			if (!$countDepth -and $callstack.peek() -ne 'main') {
				write-Log -Message "Line $($token.StartLine) - Exiting function $($callstack.peek())" -Severity VERBOSE
				# Pop the name off the stack, so we return to the previous function name
				$callStack.pop() | Out-Null
				write-Log -Message "    Current function is now: $($callStack.peek())" -Severity VERBOSE
			}
			continue
		}
		# If it is a command or CommandArgument, see if it is in the function tables, if not then register it
		if ($token.Type -eq 'CommandArgument' -or $token.Type -eq 'Command') {
			$calledFunction = ($token.Content).ToLower()
			# If the function is in a list of functions that we know about...
			if ($callGraphArray.ContainsKey($calledFunction)) {
				# ... and we have not already put this function name into it
				if ($callGraphArray[$callstack.peek()] -notcontains $calledFunction) {
					write-Log -Message "Line $($token.StartLine) - Adding $($callstack.peek()) calling $calledFunction" -Severity VERBOSE
					# Add the called function to the function being processed
					$callGraphArray[$callstack.peek()] += $calledFunction
				}
			}
		}
	}

	$callGraphArray
}


# Ensure that information log lines are written out
$informationPreference = 'Continue'

# This is the array we store the results in
$callGraphArray = @{}


# Pass 1 - iterate through all files provided on the command line
foreach ($file in ($scriptFile.split(','))) {
    $callGraphArray = Find-CallGraphPhase1 -file $file -callGraphArray $callGraphArray
}


# Pass 2 - iterate through all files provided on the command line
foreach ($file in ($scriptFile.split(','))) {
	$callGraphArray = Find-CallGraphPhase2 -file $file -callGraphArray $callGraphArray
}

# Get the name of the powershell file
$filename = Split-Path $scriptFile -Leaf

# Generate the Mermaid content
$mermaidContent += "---`n"
$mermaidContent += "title: PowerShell Script - $filename`n"
$mermaidContent += "---`n"
$mermaidContent += "graph TD`n"
foreach ($func in $callGraphArray.Keys) {
    # Does something call this function?
    if ($callGraphArray[$func].count) {
	    # ... yes, so write out the connections
	    foreach ($call in $callGraphArray[$func]) {
            $mermaidContent += "    $func --> $call`n"
        }
    } else {
	    # Function that is not called
	    $mermaidContent += "    $func`n"
    }
}

# Write the Mermaid file
Set-Content -Path $outputFile -Value $mermaidContent -NoNewLine

Write-Log -message "Call graph generated and saved to $outputFile" -Severity Info
