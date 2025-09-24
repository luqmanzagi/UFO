# Read all non-empty app names (one per line)
$apps   = Get-Content app.txt | Where-Object { $_.Trim() -ne '' }
# Read the generic prompt as one string (preserves newlines)
$common = Get-Content generic.txt -Raw

foreach ($app in $apps) {
  $request = @"
Launch application $app

$common
"@

  Write-Host "Running tests for $app"
  # Pass the request as ONE argument
  python -m ufo --task "$app" --request "$request"
}
