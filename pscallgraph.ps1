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
	PARAM(
		$sourcePath,
		$destPath
	)
	
	if ([System.IO.Path]::IsPathRooted($destPath)) {
		return $destPath
	}
	return Join-Path -Path (Split-Path -path $sourcePath) -ChildPath $destPath
}

function disposeFile {
	param (
		[string] $file
)
	write-output "Reading file $file"
	if (Test-Path -Path $file) {
		$scriptContent = (Get-Content -Path $file -Raw)
	} else {
		write-Output "*** ERROR - Unable to find file: $file"
		return	
	}

	# Read in the file
	$Tokens = [System.Management.Automation.PSParser]::Tokenize($scriptContent, [Ref] $Null) | Where-Object { $_.Type -ne 'Comment' }

	# Parse 1 - Find all the functions
	# Read the script file line by line

	write-Output "===== Parse 1 - Find functions ====="

	# This tracks if we have found a function keyword
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
			$functionName = ($token.Content).ToLower()
			# Add it to the array
			$functions[$functionName] = @()
			write-Debug "Line $($token.StartLine) - Found function: '$functionName'"
		}
	}

	write-Output "===== Parse 2 - Find Calling Functions ====="

	# Reset counters
	$countDepth = 0
	$foundFunction = $false
	$foundIncludeOperator = $false

	# Iterate over finding called functions
	foreach ($token in $Tokens) {

		# We are interested in the Type = function, then capture the command argument after it
		if (($token.Type -eq 'Keyword') -and ( $token.Content -eq 'function')) {
			$foundFunction = $true
			continue
		}
		# Record the name of the function
		if ($foundFunction) {
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
				$callStack.pop() | Out-Null
				write-debug "    Current function is now: $($callStack.peek())"
			}
			continue
		}
		# If it is a command or CommandArgument, see if it is in the function tables, if not then register it
		if ($token.Type -eq 'CommandArgument' -or $token.Type -eq 'Command') {
			$calledFunction = ($token.Content).ToLower()
			if ($functions.ContainsKey($calledFunction)) {
				if ($functions[$callstack.peek()] -notcontains $calledFunction) {
					write-debug "Line $($token.StartLine) - Adding $($callstack.peek()) calling $calledFunction"
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

$filename = Split-Path $scriptFile -Leaf
# Generate the DOT file content
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
