<# This is a multiline comment
	that finishes here
#> 

# this is a comment

. include.ps1

function write-hello ($a, $b) {
	# a comment
	write-output "Hello"
	write-goodbye
}

function write-goodbye {
	write-output "Goodbye"
}

function not-called {
	write-output 'not called'
}

write-hello
write-goodbye
