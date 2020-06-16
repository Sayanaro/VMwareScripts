#region HelperSection
function WriteVerboseMessage  {
    [CmdletBinding()]
    param (
        [string]
        $Message
    )

    $Status = "{0}: {1}" -f (Get-Date).ToString("[dd.MM.yyyy hh:mm:ss]"), $Message
    Write-Verbose $Status
}
#endregion

#region MainFunction
function Find-DuplicateCloudIDs
{
<#
    .SYNOPSIS
        Getting all VMs with identical Cloud.UUUID.
    .DESCRIPTION
        Cmdlet returns list of VMs with same Cloud.UUID.
    .PARAMETER  vCenters
        VCSA Array. Linked Mode is supported.
    .PARAMETER  Credential
        vCenter Server credentials
    .EXAMPLE
        # Connecti to 2 vCenter (one of which Linked Mode)
        Find-DuplicateCloudIDs -vCenter @("vc2.contoso.com","vc2.contoso.com") -Credential $(Get-Credential)
    .EXAMPLE
        # Export CSV
        Find-DuplicateCloudIDs -vCenter @("vc2.contoso.com","vc2.contoso.com") -Credential $(Get-Credential) | Export-Csv "duplicateUUIDS.csv" -NoTypeInformation -Encoding UTF8 -Delimiter ";"
#>
    [CmdletBinding()]
    param (
        [string[]]
        [ValidateNotNullOrEmpty()]
        $vCenters = @(),
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential
    )

    if(!$Credential)
    {
        $Credential = Get-Credential -Message "Please enter vCenter credentials."
    }

    $ConnectionString = @()

    foreach ($vCenter in $vCenters)
    {
        try {
            $ConnectionString += Connect-VIServer -Server $vCenter -Credential $Credential -NotDefault -AllLinked -Force -ErrorAction stop -WarningAction SilentlyContinue -ErrorVariable er
        }
        catch {
            if ($er.Message -like "*not part of a linked mode*")
            {
                try {
                    $ConnectionString += Connect-VIServer -Server $vCenter -Credential $Credential -NotDefault -Force -ErrorAction stop -WarningAction SilentlyContinue -ErrorVariable er
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

    $AllVMs = Get-View -viewtype VirtualMachine -Server $ConnectionString -Property Name,Config.ExtraConfig,summary.runtime.powerstate | Where-Object {($_.Config.ExtraConfig | Where-Object {$_.key -eq "cloud.uuid"}).Value -ne $null} | Select-Object @{N="VMName";E={$_.Name}},@{N="CloudUUID";E={($_.Config.ExtraConfig | Where-Object {$_.key -eq "cloud.uuid"}).Value}},@{N="PowerState";E={$_.summary.runtime.powerstate}}
    $AllVMs = $AllVMs | Sort-Object CloudUUID
    $AllVMs | Group-Object -Property CloudUUID | Where-Object -FilterScript {$_.Count -gt 1} | Select-Object -ExpandProperty Group
}
#endregion
