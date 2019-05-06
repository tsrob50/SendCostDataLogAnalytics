<#
.SYNOPSIS
    This automation script will get cost data from Azure and send the data to a Log Analytics Workspace
.DESCRIPTION
    The goal of this script is to send cost data from Azure to Log Analytics for reporting.  It runs daily, updating the total spend from the current period.  
.INPUTS
    No input for this scrip
.OUTPUTS
    The script sends biling cost, date budget and billing period to Log Analytics
.NOTES
    Version:        1.0
    Author:         Travis Roberts
    Creation Date:  4/21/2019
.EXAMPLE
    No example, just run as a scheduled task.
#>


#----------------------------------------------------------[Declarations]----------------------------------------------------------

# Script Version
$sScriptVersion = '1.0'

# Azure Monitor Log Analytics Workspace
$laType = "CiraltosSpend"

# Date
$date = Get-Date

#-----------------------------------------------------------[Functions]------------------------------------------------------------

# Logging function
function Write-OMSLogfile {
    <#
    .SYNOPSIS
    Inputs a Hashtable file and writes it to an OMS Workspace.
    .DESCRIPTION
    Given a  value pair hash table, this function will write the data to an Azure Monitor Log Analytics workspace.
    Certain variables, such as Customer ID and Shared Key are specific to the OMS workspace data is being written to.
    This function will not write to multiple OMS workspaces.  Build-signature and post-analytics function from Microsoft documentation
    at https://docs.microsoft.com/en-us/azure/log-analytics/log-analytics-data-collector-api
    .PARAMETER DateTime
    date and time for the log.  DateTime value
    .PARAMETER Type
    Name of the logfile or Log Analytics "Type".  Log Analytics will append _CL at the end of custom logs  String Value
    .PARAMETER LogData
    A series of key, value pairs that will be written to the log.  Log file are unstructured but the key should be consistent
    withing each source.
    .INPUTS
    The parameters of data and time, type and logdata.  Logdata is converted to JSON to submit to Log Analytics.
    .OUTPUTS
    The Function will return the HTTP status code from the Post method.  Status code 200 indicates the request was received.
    .NOTES
    Version:        2.0
    Author:         Travis Roberts
    Creation Date:  7/9/2018
    Purpose/Change: Crating a stand alone function.
    .EXAMPLE
    TBD
    #>
        [cmdletbinding()]
        Param(
            [Parameter(Mandatory = $true, Position = 0)]
            [datetime]$dateTime,
            [parameter(Mandatory = $true, Position = 1)]
            [string]$type,
            [Parameter(Mandatory = $true, Position = 2)]
            [Hashtable]$logdata
        )
        Write-Verbose -Message "DateTime: $dateTime"
        Write-Verbose -Message ('DateTimeKind:' + $dateTime.kind)
        Write-Verbose -Message "Type: $type"
        write-Verbose -Message "LogData: $logdata"
    
        # region Workspace ID and Key
        # Workspace ID for the workspace
        # $CustomerID = 'Enter Customer ID'
        $CustomerID = 'Enter Customer ID'
        # Shared key needs to be set for environment
        # Below uses an encrypted variable from Azure Automation
        # Uncomment the next two lines if using Azure Automation Variable and comment the last
        # $automationVarName = 'LogAnalyticsKey'
        # $sharedKey = Get-AutomationVariable -name $automationVarName
        # Key Vault is another secure option for storing the value
        # Less secure option is to put the key in the code
        $SharedKey = 'Enter Key Here'
        #endregion
    
        # Supporting Functions
        # Function to create the auth signature
        function Build-signature ($CustomerID, $SharedKey, $Date, $ContentLength, $method, $ContentType, $resource) {
            $xheaders = 'x-ms-date:' + $Date
            $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
            $bytesToHash = [text.Encoding]::UTF8.GetBytes($stringToHash)
            $keyBytes = [Convert]::FromBase64String($SharedKey)
            $sha256 = New-Object System.Security.Cryptography.HMACSHA256
            $sha256.key = $keyBytes
            $calculateHash = $sha256.ComputeHash($bytesToHash)
            $encodeHash = [convert]::ToBase64String($calculateHash)
            $authorization = 'SharedKey {0}:{1}' -f $CustomerID,$encodeHash
            return $authorization
        }
        # Function to create and post the request
        Function Post-LogAnalyticsData ($CustomerID, $SharedKey, $Body, $Type) {
            $method = "POST"
            $ContentType = 'application/json'
            $resource = '/api/logs'
            $rfc1123date = ($dateTime).ToString('r')
            $ContentLength = $Body.Length
            $signature = Build-signature `
                -customerId $CustomerID `
                -sharedKey $SharedKey `
                -date $rfc1123date `
                -contentLength $ContentLength `
                -method $method `
                -contentType $ContentType `
                -resource $resource
            $uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
            $headers = @{
                "Authorization" = $signature;
                "Log-Type" = $type;
                "x-ms-date" = $rfc1123date
                "time-generated-field" = $dateTime
            }
            $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $ContentType -Headers $headers -Body $body -UseBasicParsing
            Write-Verbose -message ('Post Function Return Code ' + $response.statuscode)
            return $response.statuscode
        }
    
        # Check if time is UTC, change to UTC if not.
    
        if ($dateTime.kind.tostring() -ne 'Utc'){
            $dateTime = $dateTime.ToUniversalTime()
            Write-Verbose -Message $dateTime
        }
    
        # Add DateTime to hashtable
        $logdata.add("DateTime", $dateTime)
    
        #Build the JSON file
        $logMessage = ConvertTo-Json $logdata
        Write-Verbose -Message $logMessage
    
        #Submit the data
        $returnCode = Post-LogAnalyticsData -CustomerID $CustomerID -SharedKey $SharedKey -Body ([System.Text.Encoding]::UTF8.GetBytes($logMessage)) -Type $type
        Write-Verbose -Message "Post Statement Return Code $returnCode"
        return $returnCode
    }
    

#-----------------------------------------------------------[Execution]------------------------------------------------------------
# Log Into Azure Automation
# RunAs Account needs read access to Azure Cost Management
# Use other Service Principle if needed
# Connect to Azure with RunAs account
$conn = Get-AutomationConnection -Name "AzureRunAsConnection"

# Connect to Azure Automaiton
$null = Add-AzureRmAccount `
  -ServicePrincipal `
  -TenantId $conn.TenantId `
  -ApplicationId $conn.ApplicationId `
  -CertificateThumbprint $conn.CertificateThumbprint

# Build content
# Get the budget amount
$Budget = (Get-AzConsumptionBudget).Amount

# Gets the billing period.  
$billingPeriod = ((get-date).AddMonths(1)).ToString("yyyyMM")

# Get the day, format month, day, year
$day = (get-date).AddDays(-1).ToString("MM-dd-yyyy")

# Gets the usage details
$usageDetail = Get-AzConsumptionUsageDetail -BillingPeriodName $billingPeriod

# Gets the sum amount owed this billing period
$billingSum = [math]::Round((((($usageDetail).PreTaxCost) | Measure-Object -Sum).sum))

# Build the hash table of values to send to Log Analytics
$SubCost = @{
    Budget = $Budget
    Day     = $day
    Period  = $billingPeriod
    Spend   = $billingSum
}

# Send Data to Log Analytics
Write-OMSLogfile -dateTime $date -type $laType -logdata $SubCost
