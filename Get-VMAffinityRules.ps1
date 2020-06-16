function Get-VMAffinityRules
{
<#
    .SYNOPSIS
        Getting Cluster affinity rules for all VM in vCloud Director Organization.
    .DESCRIPTION
        Getting Affinity and Anti-Affinity rules for organization in vCloud Director.
    .PARAMETER  vCloudDirector
        vCloud Director FQDN
    .PARAMETER  Organization
        Org name in vCloud Director
    .PARAMETER  vCenters
        VCSA list (linked mode is supported)
    .PARAMETER  MaxThreads
        Count of parallel threads
    .PARAMETER  CloudCredential
        vCloud Director Credentials
    .PARAMETER  vCenterCredential
        vCenter Credentials
    .EXAMPLE
        Get-VMAffinityRules -vCloudDirector cloud.contoso.com -Organization "MyOrg" -vCenters @("vcsa.contoso.com") -MaxThreads 32
    .EXAMPLE
        Get-VMAffinityRules -vCloudDirector cloud.contoso.com -Organization "MyOrg" -vCenters @("vcsa.contoso.com") -MaxThreads 64 -CloudCredential $(Get-Credential) -vCenterCredential $(Get-Credential) | Export-Csv "OrgAffinityRules.csv" -NoTypeInformation -Encoding UTF8 -Delimiter ";"
#>
    [CmdletBinding()]
    param (
        [string]
        [ValidateNotNullOrEmpty()]
        $vCloudDirector,
        [string]
        [ValidateNotNullOrEmpty()]
        $Organization,
        [string[]]
        [ValidateNotNullOrEmpty()]
        $vCenters = @(),
        [int]
        $MaxThreads = 32,
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $CloudCredential,
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $vCenterCredential
    )

    if(!$CloudCredential)
    {
        $vCenterCredential = Get-Credential -Message "Please enter vCloud Director credentials."
    }

    if(!$vCenterCredential)
    {
        $vCenterCredential = Get-Credential -Message "Please enter vCenter credentials."
    }

    $CIServier = Connect-CIServer -Server $vCloudDirector -Credential $CloudCredential
    $OrgVDC = Get-Org $Organization | Get-OrgVdc | Get-CIVM

    $ConnectionString = @()

    foreach ($vCenter in $vCenters)
    {
        try {
            $ConnectionString += Connect-VIServer -Server $vCenter -Credential $vCenterCredential -NotDefault -AllLinked -Force -ErrorAction stop -WarningAction SilentlyContinue -ErrorVariable er
        }
        catch {
            if ($er.Message -like "*not part of a linked mode*")
            {
                try {
                    $ConnectionString += Connect-VIServer -Server $vCenter -Credential $vCenterCredential -NotDefault -Force -ErrorAction stop -WarningAction SilentlyContinue -ErrorVariable er
                }
                catch {
                    throw $_
                }
                    
            }
            else {
                throw $_
            }
        }
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
            $CIObject,
            $ConnectionString
        )

        $Result = "" | Select-Object Org,vDC,vApp,VMCloudName,VMName,RuleName,IsEnabled

        $VMName = $CIObject.Name
        Write-Verbose "Processing VM $VMName"
        $VM = Get-View -Server $ConnectionString -ViewType VirtualMachine -Filter @{"Name"="$VMName*"} -Property Name,Runtime
        $VMHostID = $VM.Runtime.Host.Value
        $VMID = $VM.MoRef.Value

        $Cluster = Get-View -Server $ConnectionString -ViewType ComputeResource -Filter @{"Host"="$VMHostID"}

        #DRS Rules
        $Rules = $Cluster.Configuration.Rule | Where-Object {$_.VM -ne $null} | Where-Object {$_.VM.Value -eq "$VMID"}

        if($Rules)
        {
            $Result.VMCloudName = $VMName
            $Result.VMName = $VM.Name
            $Result.Org = $CIObject.Org
            $Result.vDC = $CIObject.OrgVdc
            $Result.VApp = $CIObject.VApp
            $Result.RuleName = $Rules.Name
            $Result.IsEnabled = $Rules.Enabled
            $Result
        }
    }
#endregion

    # Creating threads
    foreach($CIObject in $OrgVDC) {
        $PowershellThread = [PowerShell]::Create()
        $null = $PowershellThread.AddScript($scriptblock)
        $null = $PowershellThread.AddArgument($CIObject)
        $null = $PowershellThread.AddArgument($ConnectionString)
        $PowershellThread.RunspacePool = $RunspacePool
        $Handle = $PowershellThread.BeginInvoke()
        $Job = "" | Select-Object Handle, Thread, object
        $Job.Handle = $Handle
        $Job.Thread = $PowershellThread
        $Job.Object = $CIObject.ToString()
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
