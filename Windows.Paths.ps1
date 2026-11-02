# Explicit extended Windows file paths work in PS5.1 without registry changes.
# Keep stored identities and displayed paths in their ordinary logical form.
function ConvertFrom-RemoteAgentsIOPath([string]$Path) {
    if($Path.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)){return '\\'+$Path.Substring(8)}
    if($Path.StartsWith('\\?\',[StringComparison]::OrdinalIgnoreCase)){return $Path.Substring(4)}
    return $Path
}
function ConvertTo-RemoteAgentsIOPath([string]$Path) {
    if([IO.Path]::DirectorySeparatorChar -ne '\'){return $Path}
    # Normalize in logical form first. Device-prefixed GetFullPath can preserve
    # dot segments, which must never weaken later scope comparisons.
    $full=[IO.Path]::GetFullPath((ConvertFrom-RemoteAgentsIOPath $Path))
    if($full.StartsWith('\\')){return '\\?\UNC\'+$full.Substring(2)}
    return '\\?\'+$full
}
