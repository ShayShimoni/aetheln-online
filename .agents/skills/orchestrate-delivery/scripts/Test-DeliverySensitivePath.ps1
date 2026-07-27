[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string]$RelativePath
)

$RelativePath -match (
	'(?i)(^|[\\/])\.env($|\.)|' +
	'(^|[\\/])(credentials?|secrets?|private[_-]?keys?)(\.[^\\/]+)?([\\/]|$)|' +
	'(^|[\\/])(id_(rsa|dsa|ecdsa|ed25519)(\.pub)?|' +
	'\.npmrc|\.netrc|_netrc|\.pypirc|\.git-credentials|' +
	'auth\.json|kubeconfig|client[_-]?secret[^\\/]*|' +
	'service[_-]?account[^\\/]*)([\\/]|$)|' +
	'\.(pem|key|p12|pfx)$'
)
