﻿$githubOwner = "githubOwner"
$token = "token"
$defaultRepository = "repo"

$gitHubHelperPath = Join-Path $PSScriptRoot "..\Actions\Github-Helper.psm1" -Resolve
Import-Module $gitHubHelperPath -DisableNameChecking

function SetTokenAndRepository {
    Param(
        [string] $githubOwner,
        [string] $token,
        [string] $repository,
        [switch] $github
    )

    $script:githubOwner = $githubOwner
    $script:token = $token
    $script:defaultRepository = $repository

    if ($github) {
        invoke-git config --global user.email "$githubOwner@users.noreply.github.com"
        invoke-git config --global user.name "$githubOwner"
        invoke-git config --global hub.protocol https
        invoke-git config --global core.autocrlf true
    }
    $token | invoke-gh auth login --with-token
}

function ConvertTo-HashTable {
    Param(
        [parameter(ValueFromPipeline)]
        [PSCustomObject] $object,
        [switch] $recurse
    )
    $ht = @{}
    if ($object) {
        $object.PSObject.Properties | ForEach-Object { 
            if ($recurse -and ($_.Value -is [PSCustomObject])) {
                $ht[$_.Name] = ConvertTo-HashTable $_.Value -recurse
            }
            else {
                $ht[$_.Name] = $_.Value
            }
        }
    }
    $ht
}

function Get-PlainText {
    Param(
        [parameter(ValueFromPipeline, Mandatory = $true)]
        [System.Security.SecureString] $SecureString
    )
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString);
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr);
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeBSTR($bstr);
    }
}

function Add-PropertiesToJsonFile {
    Param(
        [string] $path,
        [hashTable] $properties,
        [Switch] $commit
    )

    Write-Host -ForegroundColor Yellow "`nAdd Properties to $([System.IO.Path]::GetFileName($path))"
    Write-Host "Properties"
    $properties | Out-Host

    $json = Get-Content $path -Encoding UTF8 | ConvertFrom-Json | ConvertTo-HashTable -recurse
    $properties.Keys | ForEach-Object {
        $json."$_" = $properties."$_"
    }
    $json | ConvertTo-Json | Set-Content $path -Encoding UTF8

    if ($commit) {
        CommitAndPush -commitMessage "Add properties to $([System.IO.Path]::GetFileName($path))"
    }
}


function DisplayTokenAndRepository {
    Write-Host "Token: $token"
    Write-Host "Repo: $defaultRepository"
}

function RunWorkflow {
    Param(
        [string] $name,
        [hashtable] $parameters = @{},
        [switch] $wait,
        [string] $repository = $defaultRepository,
        [string] $branch = "main"
    )

    Write-Host -ForegroundColor Yellow "`nRun workflow $($name.Trim()) in $repository"
    if ($parameters -and $parameters.Count -gt 0) {
        Write-Host "Parameters:"
        Write-Host ($parameters | ConvertTo-Json)
    }

    $headers = @{ 
      "Accept" = "application/vnd.github.v3+json"
      "Authorization" = "token $token"
    }

    $rate = ((InvokeWebRequest -Headers $headers -Uri "https://api.github.com/rate_limit" -retry).Content | ConvertFrom-Json).rate
    $percent = [int]($rate.remaining*100/$rate.limit)
    Write-Host "$($rate.remaining) API calls remaining out of $($rate.limit) ($percent%)"
    if ($percent -lt 10) {
        $resetTimeStamp = ([datetime] '1970-01-01Z').AddSeconds($rate.reset)
        $waitTime = $resetTimeStamp.Subtract([datetime]::Now)
        Write-Host "Less than 10% API calls left, waiting for $($waitTime.TotalSeconds) seconds for limits to reset."
        Start-Sleep -seconds ($waitTime.TotalSeconds+1)
    }

    Write-Host "Get Workflows"
    $url = "https://api.github.com/repos/$repository/actions/workflows"
    $workflows = (InvokeWebRequest -Method Get -Headers $headers -Uri $url -retry | ConvertFrom-Json).workflows
    $workflows | ForEach-Object { Write-Host "- $($_.Name)"}
    if (!$workflows) {
        Write-Host "No workflows found, waiting 60 seconds and retrying"
        Start-Sleep -seconds 60
        $workflows = (InvokeWebRequest -Method Get -Headers $headers -Uri $url -retry | ConvertFrom-Json).workflows
        $workflows | ForEach-Object { Write-Host "- $($_.Name)"}
        if (!$workflows) {
            throw "No workflows found"
        }
    }
    $workflow = $workflows | Where-Object { $_.Name.Trim() -eq $name }
    if (!$workflow) {
        throw "Workflow $name not found"
    }

    Write-Host "Get Previous runs"
    $url = "https://api.github.com/repos/$repository/actions/runs"
    $previousrun = (InvokeWebRequest -Method Get -Headers $headers -Uri $url -retry | ConvertFrom-Json).workflow_runs | Where-Object { $_.workflow_id -eq $workflow.id -and $_.event -eq 'workflow_dispatch' } | Select-Object -First 1
    if ($previousrun) {
        Write-Host "Previous run: $($previousrun.id)"
    }
    else {
        Write-Host "No previous run found"
    }
    
    Write-Host "Run workflow"
    $url = "https://api.github.com/repos/$repository/actions/workflows/$($workflow.id)/dispatches"
    Write-Host $url
    $body = @{
        "ref" = "refs/heads/$branch"
        "inputs" = $parameters
    }
    InvokeWebRequest -Method Post -Headers $headers -Uri $url -retry -Body ($body | ConvertTo-Json) | Out-Null

    Write-Host "Queuing"
    do {
        Start-Sleep -Seconds 10
        $url = "https://api.github.com/repos/$repository/actions/runs"
        $run = (InvokeWebRequest -Method Get -Headers $headers -Uri $url -retry | ConvertFrom-Json).workflow_runs | Where-Object { $_.workflow_id -eq $workflow.id -and $_.event -eq 'workflow_dispatch' } | Select-Object -First 1
        Write-Host "."
    } until (($run) -and ((!$previousrun) -or ($run.id -ne $previousrun.id)))
    $runid = $run.id
    Write-Host "Run URL: https://github.com/$repository/actions/runs/$runid"
    if ($wait) {
        WaitWorkflow -repository $repository -runid $run.id
    }
    $run
}

function WaitWorkflow {
    Param(
        [string] $repository = $defaultRepository,
        [string] $runid
    )

    $headers = @{ 
        "Accept" = "application/vnd.github.v3+json"
        "Authorization" = "token $token"
    }

    $status = ""
    do {
        Start-Sleep -Seconds 60
        $url = "https://api.github.com/repos/$repository/actions/runs/$runid"
        $run = (InvokeWebRequest -Method Get -Headers $headers -Uri $url | ConvertFrom-Json)
        if ($run.status -ne $status) {
            if ($status) { Write-Host }
            $status = $run.status
            Write-Host -NoNewline "$status"
        }
        Write-Host -NoNewline "."
    } while ($run.status -eq "queued" -or $run.status -eq "in_progress")
    Write-Host
    Write-Host $run.conclusion
    if ($run.conclusion -ne "Success") {
        throw "Workflow $name failed, url = $($run.html_url)"
    }
}

function SetRepositorySecret {
    Param(
        [string] $repository = $defaultRepository,
        [string] $name,
        [string] $value
    )

    invoke-gh secret set $name -b $value --repo $repository -returnValue
}

function CreateRepository {
    Param(
        [switch] $github,
        [string] $repository = $defaultRepository,
        [string] $template = "",
        [string] $contentPath,
        [switch] $private,
        [switch] $linux,
        [string] $branch = "main",
        [hashtable] $applyRepoSettings = @{},
        [hashtable] $applyAlGoSettings = @{}
    )

    if (!$template.Contains('@')) {
        $template += '@main'
    }
    $templateBranch = $template.Split('@')[1]
    $templateRepo = $template.Split('@')[0]

    $tempPath = [System.IO.Path]::GetTempPath()
    $path = Join-Path $tempPath ([GUID]::NewGuid().ToString())
    New-Item $path -ItemType Directory | Out-Null
    Set-Location $path
    if ($private) {
        Write-Host -ForegroundColor Yellow "`nCreating private repository $repository (based on $template)"
        invoke-gh repo create $repository --private --clone
    }
    else {
        Write-Host -ForegroundColor Yellow "`nCreating public repository $repository (based on $template)"
        invoke-gh repo create $repository --public --clone
    }
    Start-Sleep -seconds 10
    Set-Location '*'

    $templateUrl = "$templateRepo/archive/refs/heads/$templateBranch.zip"
    $zipFileName = Join-Path $tempPath "$([GUID]::NewGuid().ToString()).zip"
    [System.Net.WebClient]::new().DownloadFile($templateUrl, $zipFileName)
    
    $tempRepoPath = Join-Path $tempPath ([GUID]::NewGuid().ToString())
    Expand-Archive -Path $zipFileName -DestinationPath $tempRepoPath
    Copy-Item (Join-Path (Get-Item "$tempRepoPath\*").FullName '*') -Destination . -Recurse -Force
    Remove-Item -Path $tempRepoPath -Force -Recurse
    Remove-Item -Path $zipFileName -Force
    if ($contentPath) {
        Write-Host "$(Join-Path $contentPath '*')"
        Copy-Item (Join-Path $contentPath '*') -Destination . -Recurse -Force
    }
    $repoSettingsFile = ".github\AL-Go-Settings.json"
    $repoSettings = Get-Content $repoSettingsFile -Encoding UTF8 | ConvertFrom-Json
    $runson = "windows-latest"
    $shell = "powershell"
    if ($private) {
        $repoSettings | Add-Member -MemberType NoteProperty -Name "gitHubRunner" -Value "self-hosted"
        $repoSettings | Add-Member -MemberType NoteProperty -Name "gitHubRunnerShell" -Value "powershell"
        $runson = "self-hosted"
    }
    if ($linux) {
        $runson = "ubuntu-latest"
        $shell = "pwsh"
    }

    if ($runson -ne "windows-latest" -or $shell -ne "powershell") {
        $repoSettings | Add-Member -MemberType NoteProperty -Name "runs-on" -Value $runson
        $repoSettings | Add-Member -MemberType NoteProperty -Name "shell" -Value $shell
        Get-ChildItem -Path '.\.github\workflows\*.yaml' | Where-Object { $_.BaseName -ne "UpdateGitHubGoSystemFiles" -and $_.BaseName -ne "PullRequestHandler" } | ForEach-Object {
            Write-Host $_.FullName
            $content = (Get-Content -Path $_.FullName -Encoding UTF8 -Raw -Force).Replace("`r", "").TrimEnd("`n").Replace("`n", "`r`n")
            $srcPattern = "runs-on: [ windows-latest ]`r`n"
            $replacePattern = "runs-on: [ $runson ]`r`n"
            $content = $content.Replace($srcPattern, $replacePattern)
            $srcPattern = "shell: powershell`r`n"
            $replacePattern = "shell: $shell`r`n"
            $content = $content.Replace($srcPattern, $replacePattern)
            Set-Content -Path $_.FullName -Encoding UTF8 -Value $content
        }
    }
    $repoSettings | ConvertTo-Json -Depth 99 | Set-Content $repoSettingsFile -Encoding UTF8
    if ($applyRepoSettings.Keys.Count) {
        Add-PropertiesToJsonFile -path $repoSettingsFile -properties $applyRepoSettings
    }
    if ($applyAlGoSettings.Keys.Count) {
        Add-PropertiesToJsonFile -path ".AL-Go\settings.json" -properties $applyAlGoSettings
    }

    invoke-git add *
    invoke-git commit --allow-empty -m 'init'
    invoke-git branch -M $branch
    if ($githubOwner -and $token) {
        invoke-git remote set-url origin "https://$($githubOwner):$token@github.com/$repository.git"
    }
    invoke-git push --set-upstream origin $branch
    if (!$github) {
        Start-Process "https://github.com/$repository"
    }
    Start-Sleep -seconds 10
}

function Pull {
    Param(
        [string] $branch = "main"
    )

    invoke-git pull origin $branch
}

function CommitAndPush {
    Param(
        [string] $serverUrl,
        [string] $commitMessage = "commitmessage"
    )

    invoke-git add *
    invoke-git commit --allow-empty -m "'$commitMessage'"
    invoke-git push $serverUrl
}

function MergePRandPull {
    Param(
        [string] $repository = $defaultRepository,
        [string] $branch = "main"
    )

    $phs = @(invoke-gh -returnValue pr list --repo $repository)
    if ($phs.Count -eq 0) {
        throw "No Pull Request was created"
    }
    elseif ($phs.Count -gt 1) {
        throw "More than one Pull Request exists"
    }
    $prid = $phs.Split("`t")[0]
    Write-Host -ForegroundColor Yellow "`nMerge Pull Request $prid into repository $repository"
    invoke-gh pr merge $prid --squash --delete-branch --repo $repository | Out-Host
    Pull -branch $branch
    Start-Sleep -Seconds 30
}

function RemoveRepository {
    Param(
        [string] $repository = $defaultRepository,
        [string] $path = ""
    )

    if ($repository) {
        Write-Host -ForegroundColor Yellow "`nRemoving repository $repository"
        invoke-gh repo delete $repository --confirm | Out-Host

        $owner = $repository.Split("/")[0]
        @(invoke-gh api -H "Accept: application/vnd.github+json" /orgs/$owner/packages?package_type=nuget -silent -returnvalue -ErrorAction SilentlyContinue | ConvertFrom-Json) | Where-Object { $_.repository.full_name -eq $repo } | ForEach-Object {
            Write-Host "- $($_.name)"
            invoke-gh api --method DELETE -H "Accept: application/vnd.github+json" /orgs/$owner/packages/nuget/$($_.name)
        }
    }

    if ($path) {
        if (-not $path.StartsWith("$([System.IO.Path]::GetTempPath())",[StringComparison]::InvariantCultureIgnoreCase)) {
            throw "$path is not temppath"
        }
        else {
            Set-Location ([System.IO.Path]::GetTempPath())
            Remove-Item $path -Recurse -Force
        }
    }
}

. (Join-Path $PSScriptRoot "Workflows\Run-AddExistingAppOrTestApp.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-CICD.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-CreateApp.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-CreateOnlineDevelopmentEnvironment.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-CreateRelease.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-CreateTestApp.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-IncrementVersionNumber.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-PublishToEnvironment.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-UpdateAlGoSystemFiles.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-TestCurrent.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-TestNextMinor.ps1")
. (Join-Path $PSScriptRoot "Workflows\Run-TestNextMajor.ps1")

. (Join-Path $PSScriptRoot "Test-Functions.ps1")
