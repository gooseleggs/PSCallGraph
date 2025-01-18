<#
Filename: PSCallGraph.ps1
Purpose: To read a powershell script and create a call graph with mermaid for functions defined within the file
Written By: Kelvin Smith - 2024
Version: 1.0

Parameters:
 - scriptFile - Name and path to the source file - can pass multiple files in using a comma to separate
 - outputFile - Name and path of the mermaid diagram
#>

Param(
    [Parameter(Mandatory = $true,
        ParameterSetName = 'Local')]
    [string[]]$scriptFile,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile = (Get-Location).Path

)

# Initialize a hashtable to store functions and their calls
$functions = @{}

# As there is no function called main, define it exclusively
$functions['main'] = @()

# Use a LIFO stack for current function
$callStack = New-Object System.Collections.Stack
$callStack.push('main')

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

function disposeFile {
<#
	.SYNOPSIS
		Reads through a PowerShell script building a call graph

	.DESCRIPTION
		This function reads through a powershell script to find all functions defined within the script and
		all functions that call those defined functions.  If the script dot sources another script this is
		read in as well and processed.  This function is recursive.

	.PARAMETER file
		The path and file name of the file to be read.  It is assumed to be a .ps1 file

	.EXAMPLE
		disposeFile -file 'C:\temp\test.ps1'

	.INPUTS
		String

	.OUTPUTS
		Does not return anything, however, it expands the global variable $functions (which must be defined
		outside of the function, such as

		# Initialize a hashtable to store functions and their calls
		$functions = @{}

		# As there is no function called main, define it exclusively
		$functions['main'] = @()
#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string] $file
)
	write-output "Reading file $file"
	if (Test-Path -Path $file) {
		$scriptContent = (Get-Content -Path $file -Raw)
	} else {
		write-Output "*** ERROR - Unable to find file: $file"
		return	
	}

	# Convert the file into tokens for processing
	$Tokens = [System.Management.Automation.PSParser]::Tokenize($scriptContent, [Ref] $Null) | Where-Object { $_.Type -ne 'Comment' }

	# Parse 1 - Find all the functions
	# Read the script file line by line

	write-Output "===== Parse 1 - Find functions ====="

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
			$functions[$functionName] = @()
			write-Debug "Line $($token.StartLine) - Found function: '$functionName'"
		}
	}

	write-Output "===== Parse 2 - Find Calling Functions ====="

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
			write-Debug "Line $($token.StartLine) - Found function: '$($callstack.peek())'"
			continue
		}
		# If there is a . operator by itself, it may be an include operation so flag for next token
		if ($token.Type -eq 'Operator' -and $token.Content -eq '.') {
				$foundIncludeOperator = $true
				continue
		}
		# If we are signaling an include operator, and this token is a command, try and dispose it
		if ($foundIncludeOperator) {
			if ($token.Type -eq 'Command') {
					Write-Output "Found included file $($token.Content) - Disposing"
					disposeFile -file ( Get-ResolvePath -sourcePath $file -destPath $token.Content)
					Write-Output "Finished Disposing file $($token.Content)"
			}
			$foundIncludeOperator = $false
			continue
		}
		# Track what depth we are in
		if ($token.Type -eq 'GroupStart' -and ($token.Content -eq '{' -or $token.Content -eq '@{')) {
			$countDepth++
	#		write-debug "Line $($token.StartLine) - GroupDepth is $countDepth"
			continue
		}
		# If we return to depth 0, then we have exited the function
		if ($token.Type -eq 'GroupEnd' -and $token.Content -eq '}') {
			$countDepth--
	#		write-debug "Line $($token.StartLine) - GroupDepth is $countDepth"
			if (!$countDepth -and $callstack.peek() -ne 'main') {
				write-debug "Line $($token.StartLine) - Exiting function $($callstack.peek())"
				# Pop the name off the stack, so we return to the previous function name
				$callStack.pop() | Out-Null
				write-debug "    Current function is now: $($callStack.peek())"
			}
			continue
		}
		# If it is a command or CommandArgument, see if it is in the function tables, if not then register it
		if ($token.Type -eq 'CommandArgument' -or $token.Type -eq 'Command') {
			$calledFunction = ($token.Content).ToLower()
			# If the function is in a list of functions that we know about...
			if ($functions.ContainsKey($calledFunction)) {
				# ... and we have not already put this function name into it
				if ($functions[$callstack.peek()] -notcontains $calledFunction) {
					write-debug "Line $($token.StartLine) - Adding $($callstack.peek()) calling $calledFunction"
					# Add the called function to the function being processed
					$functions[$callstack.peek()] += $calledFunction
				}
			}
		}
	}
}

# iterate through all files provided on the command line
foreach ($file in ($scriptFile.split(','))) {
	disposeFile -file $file
}

# Get the name of the powershell file
$filename = Split-Path $scriptFile -Leaf
# Generate the Mermaid content
$mermaidContent += "---`n"
$mermaidContent += "title: PowerShell Script - $filename`n"
$mermaidContent += "---`n"
$mermaidContent += "graph TD`n"
foreach ($func in $functions.Keys) {
	# Does something call this function?
	if ($functions[$func].count) {
		# ... yes, so write out the connections
		foreach ($call in $functions[$func]) {
			$mermaidContent += "    $func --> $call`n"
		}
	} else {
		# Function that is not called
		$mermaidContent += "    $func`n"
	}
}

# Write the Mermaid file
Set-Content -Path $outputFile -Value $mermaidContent -NoNewLine

Write-Output "Call graph generated and saved to $outputFile"
