function Get-DatastoreEmptyFolders
{
<#
    .NOTES
        Copyright DataLine Ltd.
        Authors: Evgeniy Parfenov and Alexey Darchenkov
    .SYNOPSIS
        Getting all non-VM catalogs on datastore.
    .DESCRIPTION
        Cmdlet looks for non-VM catalogs on VMware ESXi Datastore.
    .PARAMETER  vCenters
        vCenter Server list.
    .PARAMETER  MaxThreads
        Value of parallel threads.
    .PARAMETER  Credential
        vCenter Server credentials.
    .EXAMPLE
        # Getting non-vm folders and export to CSV
        Get-DatastoreEmptyFolders -vCenter "vc2.contoso.com" -DatastoreName "vSanDatastore" -Credential $(Get-Credential) -MaxThreads 64 | Export-Csv "vSAN55-EmptyFolders.csv" -NoTypeInformation -Encoding UTF8 -Delimeter ";"
#>
    [CmdletBinding()]
    param(
        [string]
        $vCenter,
        [string]
        [ValidateNotNullOrEmpty()]
        $DatastoreName,
        [int]$MaxThreads = 32,
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    # Getting credentials if it's null
    
    if($vCenter)
    {
        $ConnectionString = @()
        if(!$Credential)
        {
            $Credential = Get-Credential -Message "Please enter vCenter credentials."
        }

        # Connecting to VCSA
        try {
            $ConnectionString += Connect-VIServer -Server $vCenter -Credential $Credential -NotDefault -Force -ErrorAction stop -WarningAction SilentlyContinue -ErrorVariable er
        }
        catch {
            throw $_
        }
    }

    # Getting Datastore's catalog tree
    try {
        $Datastore = @()

        if($ConnectionString)
        {
            $Datastore += Get-Datastore $DatastoreName -Server $ConnectionString -ErrorAction stop
        }
        else {
            $Datastore += Get-Datastore $DatastoreName -ErrorAction stop
        }
    }
    catch {
        throw $_
    }

    try {
        $DSRootItems = Get-ChildItem $Datastore[0].DatastoreBrowserPath -ErrorAction stop
    }
    catch {
        throw $_
    }

    $DatastoreMountPoint = "/vmfs/volumes/$DatastoreName/"
    
    try {
        if($ConnectionString)
        {
            $DatastoreData = Get-View $Datastore[0].Id -Server $ConnectionString -ErrorAction stop
        }
        else {
            $DatastoreData = Get-View $Datastore[0].Id -ErrorAction stop
        }
    }
    catch {
        throw $_
    }

    # Creating search query
    $FileQueryFlags = New-Object VMware.Vim.FileQueryFlags
    $FileQueryFlags.FileSize = $true
    $FileQueryFlags.FileType = $true
    $fileQueryFlags.fileOwner = $false
    $fileQueryFlags.Modification = $false

    $SearchSpec = New-Object VMware.Vim.HostDatastoreBrowserSearchSpec
    $SearchSpec.details = $fileQueryFlags
    $SearchSpec.sortFoldersFirst = $true

    $rootPath = "["+$DatastoreData.summary.Name+"]"

    if($ConnectionString)
    {
        $dsBrowser = Get-View $DatastoreData.browser -Server $ConnectionString
    }
    else {
        $dsBrowser = Get-View $DatastoreData.browser
    }

    # Initializing runspace pool
    $ISS = [system.management.automation.runspaces.initialsessionstate]::CreateDefault()
    $RunspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads, $ISS, $Host)
    $RunspacePool.ApartmentState = "MTA"
    $RunspacePool.Open()
    $Jobs = @()

#region ScriptBlockForFilteringCatalog
    $scriptblock = {
        Param (
            $DSRootItemName,
            $rootPath,
            $DatastoreMountPoint,
            $dsBrowser,
            $searchSpec
        )

        $FolderRoot = "$rootPath "+$DSRootItemName
        $dsBrowser.SearchDatastoreSubFolders($FolderRoot, $searchSpec) | Where-Object {($_.File.FileSize -ne 0) -and (!($_.File.Path -like "*vmdk") -or !($_.File.Path -like "*vmx"))} | Select-Object FolderPath,File -ExpandProperty File | Select-Object FolderPath,Path | Select @{N="FileName";E={$_.Path}},@{N="ParentFolder";E={$DatastoreMountPoint+$_.FolderPath.Trim("$rootPath ")}} | Select-Object FileName,@{N="FilePath";E={$_.ParentFolder+$_.FileName}},ParentFolder
    }
#endregion

    # Creating threads
    foreach($DSRootItem in $DSRootItems)
    {
        $PowershellThread = [PowerShell]::Create()
        $null = $PowershellThread.AddScript($scriptblock)
        $null = $PowershellThread.AddArgument($DSRootItem.Name)
        $null = $PowershellThread.AddArgument($rootPath)
        $null = $PowershellThread.AddArgument($DatastoreMountPoint)
        $null = $PowershellThread.AddArgument($dsBrowser)
        $null = $PowershellThread.AddArgument($searchSpec)
        $PowershellThread.RunspacePool = $RunspacePool
        $Handle = $PowershellThread.BeginInvoke()
        $Job = "" | Select-Object Handle, Thread, object
        $Job.Handle = $Handle
        $Job.Thread = $PowershellThread
        $Job.Object = $DSRootItem.ToString()
        $Jobs += $Job
    }

    # Run threads and close them after execution
    While (@($Jobs | Where-Object {$_.Handle -ne $Null}).count -gt 0)
    {
        $Remaining = "$($($Jobs | Where-Object {$_.Handle.IsCompleted -eq $False}).object)"

        If ($Remaining.Length -gt 60) {
            $Remaining = $Remaining.Substring(0,60) + "..."
        }

        Write-Progress -Activity "Waiting for Jobs - $($MaxThreads - $($RunspacePool.GetAvailableRunspaces())) of $MaxThreads threads running" -PercentComplete (($Jobs.count - $($($Jobs | Where-Object {$_.Handle.IsCompleted -eq $False}).count)) / $Jobs.Count * 100) -Status "$(@($($Jobs | Where-Object {$_.Handle.IsCompleted -eq $False})).count) remaining - $remaining"

        ForEach ($Job in $($Jobs | Where-Object {$_.Handle.IsCompleted -eq $True})){
            $Job.Thread.EndInvoke($Job.Handle)		
            $Job.Thread.Dispose()
            $Job.Thread = $Null
            $Job.Handle = $Null
        }
    }

    # Killing runspace pool
    $RunspacePool.Close() | Out-Null
    $RunspacePool.Dispose() | Out-Null
}
