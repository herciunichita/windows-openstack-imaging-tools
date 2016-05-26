$ErrorActionPreference = "Stop"
$resourcesDir = "$ENV:SystemDrive\UnattendResources"
$configIniPath = "$resourcesDir\config.ini"

function Set-PersistDrivers {
    Param(
    [parameter(Mandatory=$true)]
    [string]$Path,
    [switch]$Persist=$true
    )
    if (!(Test-Path $Path)){
        return $false
    }
    try {
        $xml = [xml](Get-Content $Path)
    }catch{
        Write-Error "Failed to load $Path"
        return $false
    }
    if (!$xml.unattend.settings){
        return $false
    }
    foreach ($i in $xml.unattend.settings) {
        if ($i.pass -eq "generalize"){
            $index = [array]::IndexOf($xml.unattend.settings, $i)
            if ($xml.unattend.settings[$index].component -and $xml.unattend.settings[$index].component.PersistAllDeviceInstalls -ne $Persist.ToString()){
                $xml.unattend.settings[$index].component.PersistAllDeviceInstalls = $Persist.ToString()
            }
        }
    }
    $xml.Save($Path)
}

function Clean-UpdateResources {
    $HOST.UI.RawUI.WindowTitle = "Running update resources cleanup"
    # We're done, disable AutoLogon
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name Unattend*
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoLogonCount

    # Cleanup
    Remove-Item -Recurse -Force $resourcesDir
    Remove-Item -Force "$ENV:SystemDrive\Unattend.xml"

}

function Clean-WindowsUpdates {
    Param(
        $PurgeUpdates
    )
    $HOST.UI.RawUI.WindowTitle = "Running Dism cleanup..."
    if (([System.Environment]::OSVersion.Version.Major -gt 6) -or ([System.Environment]::OSVersion.Version.Minor -ge 2))
    {
        if (!$PurgeUpdates) {
            Dism.exe /Online /Cleanup-Image /StartComponentCleanup
        } else {
            Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
        }
        if ($LASTEXITCODE)
        {
            throw "Dism.exe clean failed"
        }
    }
}

function Run-Defragment {
    $HOST.UI.RawUI.WindowTitle = "Running Defrag..."
    #Defragmenting all drives at normal priority
    defrag.exe /C /H /V
    if ($LASTEXITCODE)
    {
        throw "Defrag.exe failed"
    }
}

function Release-IP {
    $HOST.UI.RawUI.WindowTitle = "Releasing IP..."
    ipconfig.exe /release
    if ($LASTEXITCODE)
    {
        throw "IPconfig release failed"
    }
}

function Install-WindowsUpdates {
    Import-Module "$resourcesDir\WindowsUpdates\WindowsUpdates"
    $BaseOSKernelVersion = [System.Environment]::OSVersion.Version
    $OSKernelVersion = ($BaseOSKernelVersion.Major.ToString() + "." + $BaseOSKernelVersion.Minor.ToString())
    $KBIdsBlacklist = @{
        "6.1" = @("KB2808679", "KB2894844", "KB3019978");
        "6.2" = @("KB3013538", "KB3042058")
        "6.3" = @("KB3013538", "KB3042058")
    }
    $excludedUpdates = $KBIdsBlacklist[$OSKernelVersion]

    $updates = Get-WindowsUpdate -Verbose -ExcludeKBId $KBIdsBlacklist
    $maximumUpdates = 20
    if (!$updates.Count) {
        $updates = [array]$updates
    }
    if ($updates) {
        $availableUpdatesNumber = $updates.Count
        Write-Host "Found $availableUpdatesNumber updates. Installing..."
        $updates.Title | Out-File -Append -FilePath "C:\updates_log.txt"
        Install-WindowsUpdate -Updates $updates[0..$maximumUpdates]
        Restart-Computer -Force
    }
}

function Disable-Swap {
    $swapRegkey = "HKLM:\\System\CurrentControlSet\Control\Session Manager\Memory Management"
    Set-ItemProperty -Path $swapRegkey -Name "PagingFiles" -Value "C:\pagefile.sys 0 0"
}

try
{
    Import-Module "$resourcesDir\ini.psm1"
    $installUpdates = Get-IniFileValue -Path $configIniPath -Section "DEFAULT" -Key "InstallUpdates" -Default $false -AsBoolean
    $persistDrivers = Get-IniFileValue -Path $configIniPath -Section "DEFAULT" -Key "PersistDriverInstall" -Default $true -AsBoolean
    $purgeUpdates = Get-IniFileValue -Path $configIniPath -Section "DEFAULT" -Key "PurgeUpdates" -Default $false -AsBoolean
    $disableSwap = Get-IniFileValue -Path $configIniPath -Section "DEFAULT" -Key "DisableSwap" -Default $false -AsBoolean


    iex ((new-object net.webclient).DownloadString('https://chocolatey.org/install.ps1'))
    choco install --confirm git
    RefreshEnv.cmd
    choco install --confirm python -version 2.7.6
    RefreshEnv.cmd
    choco install --confirm pip
    RefreshEnv.cmd
    #\$env:Path += ';C:\Python27;C:\Python27\Scripts;C:\OpenSSL-Win32\bin;C:\Program Files (x86)\Git\cmd;C:\Program Files\Git\bin;C:\qemu-img'; setx PATH \$env:Path

    pushd C:\
    if ( -not (Test-Path C:\Openstack)){
    mkdir OpenStack
    }
    if ( -not (Test-Path C:\Openstack\Log)){
    mkdir OpenStack\Log
    }
    if ( -not (Test-Path C:\iSCSIVirtualDisks)){
    mkdir iSCSIVirtualDisks
    }

    popd

    if ($disableSwap) {
        Disable-Swap
    }

    if ($installUpdates) {
        Install-WindowsUpdates
    }

    Clean-WindowsUpdates -PurgeUpdates $purgeUpdates

    $Host.UI.RawUI.WindowTitle = "Installing Cloudbase-Init..."

    $programFilesDir = $ENV:ProgramFiles

    $CloudbaseInitMsiPath = "$resourcesDir\CloudbaseInit.msi"
    $CloudbaseInitMsiLog = "$resourcesDir\CloudbaseInit.log"

    $serialPortName = @(Get-WmiObject Win32_SerialPort)[0].DeviceId

    $p = Start-Process -Wait -PassThru -FilePath msiexec -ArgumentList "/i $CloudbaseInitMsiPath /qn /l*v $CloudbaseInitMsiLog LOGGINGSERIALPORTNAME=$serialPortName"
    if ($p.ExitCode -ne 0)
    {
        throw "Installing $CloudbaseInitMsiPath failed. Log: $CloudbaseInitMsiLog"
    }

    $Host.UI.RawUI.WindowTitle = "Running SetSetupComplete..."
    & "$programFilesDir\Cloudbase Solutions\Cloudbase-Init\bin\SetSetupComplete.cmd"
    

    Run-Defragment

    Clean-UpdateResources

    Release-IP

    $Host.UI.RawUI.WindowTitle = "Running Sysprep..."
    $unattendedXmlPath = "$programFilesDir\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml"
    Set-PersistDrivers -Path $unattendedXmlPath -Persist:$persistDrivers
    & "$ENV:SystemRoot\System32\Sysprep\Sysprep.exe" `/generalize `/shutdown `/oobe `/unattend:"$unattendedXmlPath"
}
catch
{
    $host.ui.WriteErrorLine($_.Exception.ToString())
    $x = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    throw
}
