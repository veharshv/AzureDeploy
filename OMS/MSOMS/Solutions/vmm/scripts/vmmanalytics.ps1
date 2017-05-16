$vmmServers = (Get-AutomationVariable -Name 'vmmServers').Split(",")
$lastRunTimestamp = Get-AutomationVariable -Name 'lastRunTime'
$currentTimestamp = Get-Date
$workSpaceId= Get-AutomationVariable -Name 'workspaceId'
$sharedKey = Get-AutomationVariable -Name 'workspaceKey'


# Create the function to create the authorization signature
Function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource)
{
    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)

    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $customerId,$encodedHash
    return $authorization
}


# Create the function to create and post the request
Function Post-OMSData($customerId, $sharedKey, $body)
{
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = Build-Signature `
        -customerId $customerId `
        -sharedKey $sharedKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -fileName $fileName `
        -method $method `
        -contentType $contentType `
        -resource $resource
    $uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"

    $headers = @{
        "Authorization" = $signature;
        "Log-Type" = "VMMjobs";
        "x-ms-date" = $rfc1123date;
        "time-generated-field" = "StartTime";
    }

    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    return $response.StatusCode

}

foreach ($server in $vmmServers)
{
    write-output ('Getting jobs data from VMM Server '+ $server)

    $vmmJobsDataForOMS = Invoke-Command -ComputerName $server -ScriptBlock {

        $server_r = args[0]
        $lastRunTimestamp_r = args[1]
        $currentTimestamp_r = args[2]

        $jobsData = Get-SCJob -All -VMMServer $server_r | where {$_.Status -ne 'Running' -and $_.EndTime -gt lastRunTimestamp_r -and $_.EndTime -le $currentTimestamp_r}
        $vmmJobsDataForOMS = @();

        foreach ($job in $jobsData) {

            $vmmJobsDataForOMS += New-Object PSObject -Property @{
            JobName = $job.CmdletName.ToString();
            Name = $job.Name.ToString();
            StartTime = $job.StartTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ");
            EndTime = $job.EndTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ");
            Duration = ($job.EndTime-$job.StartTime).TotalSeconds;     
            Progress = $job.Progress.ToString();
            Status = $job.Status.ToString();
            ErrorInfo = $job.ErrorInfo.ToString();
            Problem = $job.ErrorInfo.Problem.ToString();
            CloudProblem = $job.ErrorInfo.CloudProblem.ToString();
            RecommendedAction = $job.ErrorInfo.RecommendedAction.ToString();
            ResultObjectID = $job.ResultObjectID.ToString();
            TargetObjectID = $job.TargetObjectID.ToString();
            TargetObjectType = $job.TargetObjectType.ToString();
            ID = $job.ID.ToString();
            ServerConnection = $job.ServerConnection.ToString();
            IsRestartable = $job.IsRestartable;
            IsCompleted = $job.IsCompleted;
            VMMServer = $args[0];}
        }
           
           $vmmJobsDataForOMS = $vmmJobsDataForOMS | ConvertTo-Json;

           Return $vmmJobsDataForOMS;
           
        } -Args $server, $lastRunTimestamp, $currentTimestamp
    
    write-output ('Pushing '+ $vmmJobsDataForOMS.Count + "job records to OMS for VMM server " + $server)

    if($vmmJobsDataForOMS) {
        Post-OMSData -customerId $workSpaceId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($vmmJobsDataForOMS))
    }
}

Set-AutomationVariable -Name 'lastRunTime' -Value $currentTimestamp 
