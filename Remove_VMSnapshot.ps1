function Remove-VMSnapshot {
    <#
    .SYNOPSIS
        Remove a VM Snapshot in vCenter
    .DESCRIPTION
        Remove a VM snapshot using either a Folder location or a list of VM names.
    .EXAMPLE
        Remove-VMSnapshot -VMs *dbo* , *sql* , *dbs* , *ora* -Days '2' -folder ems -Delete
    .EXAMPLE
        Remove-VMSnapshot -Folder 'ABCProd' -Days '15' -datacenter 'am3' -Delete
    .EXAMPLE
        $VMs | Remove-VMSnapshot -Days '15' -Datacenter 'am3' -Credential $creds -Delete
    .EXAMPLE
        If you don't want to delete the snapshots and just test the script, don't include the -Delete
        Remove-VMSnapshot -Folder 'ABCProd' -Days '15' -datacenter 'am3'
    .PARAMETER Folder
        vCenter Folder Location where a list of VM's are located.
    .PARAMETER VMs
        A list of VM's to have snapshots removed.
    .PARAMETER Days 
        Snapshot needs to be older than this amount of days in order to be deleted.
    .PARAMETER Datacenter
        Datacenter where the VMs are.
    .PARAMETER Credential
        PSCredential object to connect to vCenter.
    .PARAMETER Delete
        Without the delete parameter specified the function will show you what would be deleted.
        Specify this parameter to actually delete the snapshots.
    .LINK
        https://github.com/p0w3rb0y/Remove-VMSnapshot/edit/master/Remove_VMSnapshot.ps1
    #>
    [cmdletbinding()]

    param(
        [parameter()]
        [ValidateSet('AM3', 'WO3', 'MUC', 'AM2', 'WOK', 'AUS', 'ALL', 'FRA', 'TOR', 'LIT', 'SYD')]
        [String]$Datacenter,

        [Parameter(
            ValueFromPipeline,
            ValueFromPipelineByPropertyName
        )]
        [string[]]$VMs = '*',
        
        [Parameter()]
        [string[]]$Folder = 'ems',

        [parameter(Position = 3)]
        [int]$Days = 15,

        [Parameter()]
        [int]$MaxDays = 30,

        [Parameter()]
        [ValidateNotNull()]
        [PSCredential]
        $Credential = [System.Management.Automation.PSCredential]::Empty,

        [Parameter()]
        [switch]$Delete

    )

    begin {
        Import-Module -Name vmware.deployautomation, AdminToolBox -ErrorAction Stop

        if (!$Datacenter) {
            $Datacenter = $env:COMPUTERNAME.Substring(0, 3) 
        }

        $Time = Get-Date
        $vcenterinfo = Get-vCenterInfo -Datacenter $Datacenter
        $EmailParams = @{
            To         = "email@email.com"
            From       = "email@email.com"
            SMTPServer = $vCenterInfo.smtpserver
            BodyAsHtml = $true
        }

        if (!$Credential.UserName) {
            $Password = ConvertTo-SecureString $vCenterInfo.plaintextpassword -Force -AsPlainText
            $Credential = [PSCredential]::new($vCenterInfo.username, $Password)
        }

        try {
            $Connection = Connect-VIServer $vCenterInfo.vCenter -Credential $Credential -Force -ErrorAction Stop
            "`r`nConnected to {0}" -f $vCenterInfo.vCenter
        }
        catch {
            'Unable to connect to vCenter {0} running Remove-VMSnapshot script' -f $vCenterInfo.vCenter
            $ErrorParams = @{
                Subject   = '{0}: Error connecting to vCenter: {0}' -f $vCenterInfo.vCenter
                Body = $_
            }
            Send-MailMessage @emailparams @ErrorParams
            Disconnect-VIServer -Server $Connection -Confirm:$false
            Write-Error -ErrorRecord $_ -ErrorAction Stop
        }
    }
    process {
        try {
            'Getting the list of VMs'
            foreach ($FolderName in $Folder) {
                if ($Datacenter -in 'fra', 'tor') {
                    $VMlist = Get-ChildVM -Folder $FolderName -Name $VMs -ErrorAction Stop
                }
                else {
                    $VMlist = Get-VM -Location $FolderName -Name $VMs -ErrorAction Stop
                }
            }
        }
        catch {
            $ErrorParams = @{
                Subject   = '{0}: Error getting VM list'
                Body = $_
            }
            Send-MailMessage @emailparams @ErrorParams
            Disconnect-VIServer -Server $Connection -Confirm:$false
            Write-Error -ErrorRecord $_ -ErrorAction Stop
        }

        'Getting the list of snapshots'
        $SnapshotList = $VMlist | Get-Snapshot
        $SnapshotsToKeep = $SnapshotList | Where-Object {
            ($_.Created -lt $Time.AddDays(-$Days) -and $_.Created -gt $Time.AddDays(-$MaxDays)) -and 
            $_.Name -match 'keep'
        }
        $SnapshotsToDelete = $SnapshotList | Where-Object {
            ($_.Created -lt $Time.AddDays(-$Days) -and $_.Name -notmatch 'keep') -or
            $_.Created -lt $Time.AddDays(-$MaxDays)
        }

        $DeletedSnapshots = [System.Collections.Generic.List[PSObject]]::new()
        $FailedSnapshots = [System.Collections.Generic.List[PSObject]]::new()

        foreach ($Snapshot in $SnapshotsToDelete) {
            try {
                if ($Delete) {
                    'Deleting snapshot {0} from VM {1}' -f $Snapshot.Name, $Snapshot.VM.Name
                    Remove-Snapshot -Snapshot $Snapshot -Confirm:$false -ErrorAction Stop
                }
                else {
                    'Would have deleted snapshot {0} from VM {1}' -f $snapshot.Name, $Snapshot.VM.Name
                    Remove-Snapshot -Snapshot $Snapshot -WhatIf
                }
                
                $DeletedSnapshots.Add($Snapshot)
                ''
            }
            catch {
                $FailedSnapshots.Add($Snapshot)
                $_
            }
        }

        'Getting the remaining snapshots'
        $RemainingSnapshots = $VMlist | Get-Snapshot

        foreach ($Snapshot in $DeletedSnapshots) {
            if ($Delete -and ($Snapshot.Id -in $RemainingSnapshots.Id)) {
                $FailedSnapshots.Add($Snapshot)
            }
        }

        #Create HTML tables based on whether snapshots have been deleted or kept, etc
        [string]$HTML = ''
        $FormatProperies = 'VM', 'Name', 'Created', @{Name = "SizeMB"; Expression = {"{0:N2}" -f ($_.SizeMB)}}

        if ($DeletedSnapshots) {
            if ($Delete) {
                $Message = 'The snapshots below have been deleted.'
                $DeletedEmailHtml = $DeletedSnapshots | Select-Object $FormatProperies | ConvertTo-Html -Fragment -PreContent "$Message<br>" -PostContent '<br>'
            }
            else {
                $Message = 'The snapshots below would have been deleted.'
                $DeletedEmailHtml = $DeletedSnapshots | Select-Object $FormatProperies | ConvertTo-Html -Fragment -PreContent "$Message<br>" -PostContent '<br>'
            }
            $HTML += $DeletedEmailHtml
        }

        if ($SnapshotsToKeep) {
            $Message = 'The snapshots below were not deleted, please review and delete them as soon as possible.'
            $HTML += $SnapshotsToKeep | Select-Object $FormatProperies | ConvertTo-Html -Fragment -PreContent "$Message<br>" -PostContent '<br>'
        }

        if ($FailedSnapshots) {
            $Message = 'The snapshots below failed to delete'
            $HTML += $FailedSnapshots | Select-Object $FormatProperies | ConvertTo-Html -Fragment -PreContent "$Message<br>" -PostContent '<br>'
        }

        if ($RemainingSnapshots) {
            $Message = 'The snapshots below are all the snapshots that still exist in the datacenter.'
            $RemainingSnapshotsHtml = $RemainingSnapshots | Select-Object $FormatProperies | ConvertTo-Html -Fragment -PreContent "$Message<br>" -PostContent '<br>'
        }

        if ($HTML) {
            if ($DeletedSnapshots) {
                if ($Delete) {
                    $EmailParams.Subject = '{0}: Snapshots deleted in {1}' -f $datacenter.ToUpper(), $vCenterInfo.Vcenter
                }
                else {
                    $EmailParams.Subject = '{0}: Snapshots would have been deleted in {1}' -f $datacenter.ToUpper(), $vCenterInfo.Vcenter
                }
            }
            else {
                $EmailParams.Subject = '{0}: No snapshots were deleted in {0}' -f $datacenter.ToUpper(), $vCenterInfo.Vcenter
            }
        }
        else {
            $EmailParams.Subject = '{0}: No snapshots were deleted in {0}' -f $datacenter.ToUpper(), $vCenterInfo.Vcenter
            $HTML = 'No snapshots were found older than {0} days in {1}<br><br>' -f $days, $vCenterInfo.Vcenter
        }

        #Add tables into the email body
        $CssTable = "
        <html>
        <head>
        <style type='text/css'>
        table, th, td {
        border: 1px solid black;
        border-collapse: collapse;
        }
        th, td {
        padding: 5px;
        }
        tr:nth-child(even) {
        background: lightgray;
        }
        tr:nth-child(odd) {
        background: white;
        }
        </style>
        </head>
        <body>
        $HTML
        $RemainingSnapshotsHtml
        </body>
        </html>
        "

        $EmailParams.Body = $CssTable

        try {
            "`nSending email..."
            Send-MailMessage @EmailParams
        }
        catch {
            $_
        }
    }
    end {
        Disconnect-VIServer -Server $Connection -Confirm:$false
    }
}
