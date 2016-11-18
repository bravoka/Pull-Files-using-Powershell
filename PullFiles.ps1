##################################################################
###################### Modify Variables Here ##################### 


# [CSV file] Location containing devices' data
$Csvpath = ".\Example.csv"        


<# Set the destination directory to copy the files 
    Do not include a '\' on the end of the directory path 
    Exception log for pulling the files are also stored here #>
$Storage = "F:\LogFiles"        

# Password for the C$ share
$password = "123password456"      

# Logs from the Invoke-Parallel cmdlet
$parallelLog = "F:\LogFiles\parallel.log"


# Notes on this example script. I have systems with 2 different folder structures where I need to grab from, hense PullFromPrimary and PullFromSecondary as well as $csv1 and $csv2.

      
##################################################################
##################################################################





<# Thanks to https://github.com/RamblingCookieMonster/Invoke-Parallel for this fantastic Runspaces function. 
   I include the Invoke-Parallel code directly into the script to avoid having a dependency #>
function Invoke-Parallel {

    [cmdletbinding(DefaultParameterSetName='ScriptBlock')]
    Param (   
        [Parameter(Mandatory=$false,position=0,ParameterSetName='ScriptBlock')]
            [System.Management.Automation.ScriptBlock]$ScriptBlock,

        [Parameter(Mandatory=$false,ParameterSetName='ScriptFile')]
        [ValidateScript({test-path $_ -pathtype leaf})]
            $ScriptFile,

        [Parameter(Mandatory=$true,ValueFromPipeline=$true)]
        [Alias('CN','__Server','IPAddress','Server','ComputerName')]    
            [PSObject]$InputObject,

            [PSObject]$Parameter,

            [switch]$ImportVariables,

            [switch]$ImportModules,

            [int]$Throttle = 20,

            [int]$SleepTimer = 200,

            [int]$RunspaceTimeout = 0,

			[switch]$NoCloseOnTimeout = $false,

            [int]$MaxQueue,

        [validatescript({Test-Path (Split-Path $_ -parent)})]
            [string]$LogFile = "C:\temp\log.log", # Using location variable set at top of script file

			[switch] $Quiet = $true
    )
    
    Begin {
        if( -not $PSBoundParameters.ContainsKey('MaxQueue') )
        {
            if($RunspaceTimeout -ne 0){ $script:MaxQueue = $Throttle }
            else{ $script:MaxQueue = $Throttle * 3 }
        }
        else
        {
            $script:MaxQueue = $MaxQueue
        }
        Write-Verbose "Throttle: '$throttle' SleepTimer '$sleepTimer' runSpaceTimeout '$runspaceTimeout' maxQueue '$maxQueue' logFile '$logFile'"
        if ($ImportVariables -or $ImportModules)
        {
            $StandardUserEnv = [powershell]::Create().addscript({
                $Modules = Get-Module | Select -ExpandProperty Name
                $Snapins = Get-PSSnapin | Select -ExpandProperty Name
                $Variables = Get-Variable | Select -ExpandProperty Name               
                @{
                    Variables = $Variables
                    Modules = $Modules
                    Snapins = $Snapins
                }
            }).invoke()[0]            
            if ($ImportVariables) {
                Function _temp {[cmdletbinding()] param() }
                $VariablesToExclude = @( (Get-Command _temp | Select -ExpandProperty parameters).Keys + $PSBoundParameters.Keys + $StandardUserEnv.Variables )
                Write-Verbose "Excluding variables $( ($VariablesToExclude | sort ) -join ", ")"
                $UserVariables = @( Get-Variable | Where { -not ($VariablesToExclude -contains $_.Name) } ) 
                Write-Verbose "Found variables to import: $( ($UserVariables | Select -expandproperty Name | Sort ) -join ", " | Out-String).`n"
            }
            if ($ImportModules) 
            {
                $UserModules = @( Get-Module | Where {$StandardUserEnv.Modules -notcontains $_.Name -and (Test-Path $_.Path -ErrorAction SilentlyContinue)} | Select -ExpandProperty Path )
                $UserSnapins = @( Get-PSSnapin | Select -ExpandProperty Name | Where {$StandardUserEnv.Snapins -notcontains $_ } ) 
            }
        }
            Function Get-RunspaceData {
                [cmdletbinding()]
                param( [switch]$Wait )
                Do {
                    $more = $false
                    if (-not $Quiet) {
						Write-Progress  -Activity "Running Query" -Status "Starting threads"`
							-CurrentOperation "$startedCount threads defined - $totalCount input objects - $script:completedCount input objects processed"`
							-PercentComplete $( Try { $script:completedCount / $totalCount * 100 } Catch {0} )
					}         
                    Foreach($runspace in $runspaces) {
                        $currentdate = Get-Date
                        $runtime = $currentdate - $runspace.startTime
                        $runMin = [math]::Round( $runtime.totalminutes ,2 )
                        $log = "" | select Date, Action, Runtime, Status, Details
                        $log.Action = "Removing:'$($runspace.object)'"
                        $log.Date = $currentdate
                        $log.Runtime = "$runMin minutes"
                        If ($runspace.Runspace.isCompleted) {                            
                            $script:completedCount++                       
                            if($runspace.powershell.Streams.Error.Count -gt 0) {
                                $log.status = "CompletedWithErrors"
                                Write-Verbose ($log | ConvertTo-Csv -Delimiter ";" -NoTypeInformation)[1]
                                foreach($ErrorRecord in $runspace.powershell.Streams.Error) {
                                    Write-Error -ErrorRecord $ErrorRecord
                                }
                            }
                            else {
                                $log.status = "Completed"
                                Write-Verbose ($log | ConvertTo-Csv -Delimiter ";" -NoTypeInformation)[1]
                            }
                            $runspace.powershell.EndInvoke($runspace.Runspace)
                            $runspace.powershell.dispose()
                            $runspace.Runspace = $null
                            $runspace.powershell = $null
                        }
                        ElseIf ( $runspaceTimeout -ne 0 -and $runtime.totalseconds -gt $runspaceTimeout) {                            
                            $script:completedCount++
                            $timedOutTasks = $true
                            $log.status = "TimedOut"
                            Write-Verbose ($log | ConvertTo-Csv -Delimiter ";" -NoTypeInformation)[1]
                            Write-Error "Runspace timed out at $($runtime.totalseconds) seconds for the object:`n$($runspace.object | out-string)"
                            if (!$noCloseOnTimeout) { $runspace.powershell.dispose() }
                            $runspace.Runspace = $null
                            $runspace.powershell = $null
                            $completedCount++
                        } 
                        ElseIf ($runspace.Runspace -ne $null ) {
                            $log = $null
                            $more = $true
                        }
                        if($logFile -and $log){
                            ($log | ConvertTo-Csv -Delimiter ";" -NoTypeInformation)[1] | out-file $LogFile -append
                        }
                    }
                    $temphash = $runspaces.clone()
                    $temphash | Where { $_.runspace -eq $Null } | ForEach {
                        $Runspaces.remove($_)
                    }
                    if($PSBoundParameters['Wait']){ Start-Sleep -milliseconds $SleepTimer }
                } while ($more -and $PSBoundParameters['Wait'])
            }
            if($PSCmdlet.ParameterSetName -eq 'ScriptFile')
            {
                $ScriptBlock = [scriptblock]::Create( $(Get-Content $ScriptFile | out-string) )
            }
            elseif($PSCmdlet.ParameterSetName -eq 'ScriptBlock')
            {
                [string[]]$ParamsToAdd = '$_'
                if( $PSBoundParameters.ContainsKey('Parameter') )
                {
                    $ParamsToAdd += '$Parameter'
                }
                $UsingVariableData = $Null                
                if($PSVersionTable.PSVersion.Major -gt 2)
                {
                    $UsingVariables = $ScriptBlock.ast.FindAll({$args[0] -is [System.Management.Automation.Language.UsingExpressionAst]},$True)    
                    If ($UsingVariables)
                    {
                        $List = New-Object 'System.Collections.Generic.List`1[System.Management.Automation.Language.VariableExpressionAst]'
                        ForEach ($Ast in $UsingVariables)
                        {
                            [void]$list.Add($Ast.SubExpression)
                        }
                        $UsingVar = $UsingVariables | Group SubExpression | ForEach {$_.Group | Select -First 1}
                        $UsingVariableData = ForEach ($Var in $UsingVar) {
                            Try
                            {
                                $Value = Get-Variable -Name $Var.SubExpression.VariablePath.UserPath -ErrorAction Stop
                                [pscustomobject]@{
                                    Name = $Var.SubExpression.Extent.Text
                                    Value = $Value.Value
                                    NewName = ('$__using_{0}' -f $Var.SubExpression.VariablePath.UserPath)
                                    NewVarName = ('__using_{0}' -f $Var.SubExpression.VariablePath.UserPath)
                                }
                            }
                            Catch
                            {
                                Write-Error "$($Var.SubExpression.Extent.Text) is not a valid Using: variable!"
                            }
                        }
                        $ParamsToAdd += $UsingVariableData | Select -ExpandProperty NewName -Unique
                        $NewParams = $UsingVariableData.NewName -join ', '
                        $Tuple = [Tuple]::Create($list, $NewParams)
                        $bindingFlags = [Reflection.BindingFlags]"Default,NonPublic,Instance"
                        $GetWithInputHandlingForInvokeCommandImpl = ($ScriptBlock.ast.gettype().GetMethod('GetWithInputHandlingForInvokeCommandImpl',$bindingFlags))        
                        $StringScriptBlock = $GetWithInputHandlingForInvokeCommandImpl.Invoke($ScriptBlock.ast,@($Tuple))
                        $ScriptBlock = [scriptblock]::Create($StringScriptBlock)
                        Write-Verbose $StringScriptBlock
                    }
                }                
                $ScriptBlock = $ExecutionContext.InvokeCommand.NewScriptBlock("param($($ParamsToAdd -Join ", "))`r`n" + $Scriptblock.ToString())
            }
            else
            {
                Throw "Must provide ScriptBlock or ScriptFile"; Break
            }
            Write-Debug "`$ScriptBlock: $($ScriptBlock | Out-String)"
            Write-Verbose "Creating runspace pool and session states"
            $sessionstate = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
            if ($ImportVariables)
            {
                if($UserVariables.count -gt 0)
                {
                    foreach($Variable in $UserVariables)
                    {
                        $sessionstate.Variables.Add( (New-Object -TypeName System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $Variable.Name, $Variable.Value, $null) )
                    }
                }
            }
            if ($ImportModules)
            {
                if($UserModules.count -gt 0)
                {
                    foreach($ModulePath in $UserModules)
                    {
                        $sessionstate.ImportPSModule($ModulePath)
                    }
                }
                if($UserSnapins.count -gt 0)
                {
                    foreach($PSSnapin in $UserSnapins)
                    {
                        [void]$sessionstate.ImportPSSnapIn($PSSnapin, [ref]$null)
                    }
                }
            }
            $runspacepool = [runspacefactory]::CreateRunspacePool(1, $Throttle, $sessionstate, $Host)
            $runspacepool.Open() 
            Write-Verbose "Creating empty collection to hold runspace jobs"
            $Script:runspaces = New-Object System.Collections.ArrayList        
            $bound = $PSBoundParameters.keys -contains "InputObject"
            if(-not $bound)
            {
                [System.Collections.ArrayList]$allObjects = @()
            }
            if( $LogFile ){
                New-Item -ItemType file -path $logFile -force | Out-Null
                ("" | Select Date, Action, Runtime, Status, Details | ConvertTo-Csv -NoTypeInformation -Delimiter ";")[0] | Out-File $LogFile
            }
            $log = "" | Select Date, Action, Runtime, Status, Details
                $log.Date = Get-Date
                $log.Action = "Batch processing started"
                $log.Runtime = $null
                $log.Status = "Started"
                $log.Details = $null
                if($logFile) {
                    ($log | convertto-csv -Delimiter ";" -NoTypeInformation)[1] | Out-File $LogFile -Append
                }
			$timedOutTasks = $false
    }
    Process {
        if($bound)
        {
            $allObjects = $InputObject
        }
        Else
        {
            [void]$allObjects.add( $InputObject )
        }
    }
    End {
        Try
        {
            $totalCount = $allObjects.count
            $script:completedCount = 0
            $startedCount = 0
            foreach($object in $allObjects){
                    $powershell = [powershell]::Create()                    
                    if ($VerbosePreference -eq 'Continue')
                    {
                        [void]$PowerShell.AddScript({$VerbosePreference = 'Continue'})
                    }
                    [void]$PowerShell.AddScript($ScriptBlock).AddArgument($object)
                    if ($parameter)
                    {
                        [void]$PowerShell.AddArgument($parameter)
                    }
                    if ($UsingVariableData)
                    {
                        Foreach($UsingVariable in $UsingVariableData) {
                            Write-Verbose "Adding $($UsingVariable.Name) with value: $($UsingVariable.Value)"
                            [void]$PowerShell.AddArgument($UsingVariable.Value)
                        }
                    }
                    $powershell.RunspacePool = $runspacepool
                    $temp = "" | Select-Object PowerShell, StartTime, object, Runspace
                    $temp.PowerShell = $powershell
                    $temp.StartTime = Get-Date
                    $temp.object = $object
                    $temp.Runspace = $powershell.BeginInvoke()
                    $startedCount++
                    Write-Verbose ( "Adding {0} to collection at {1}" -f $temp.object, $temp.starttime.tostring() )
                    $runspaces.Add($temp) | Out-Null
                    Get-RunspaceData
                    $firstRun = $true
                    while ($runspaces.count -ge $Script:MaxQueue) {
                        if($firstRun){
                            Write-Verbose "$($runspaces.count) items running - exceeded $Script:MaxQueue limit."
                        }
                        $firstRun = $false
                        Get-RunspaceData
                        Start-Sleep -Milliseconds $sleepTimer                    
                    }
            }         
            Write-Verbose ( "Finish processing the remaining runspace jobs: {0}" -f ( @($runspaces | Where {$_.Runspace -ne $Null}).Count) )
            Get-RunspaceData -wait
            if (-not $quiet) {
			    Write-Progress -Activity "Running Query" -Status "Starting threads" -Completed
		    }
        }
        Finally
        {
            if ( ($timedOutTasks -eq $false) -or ( ($timedOutTasks -eq $true) -and ($noCloseOnTimeout -eq $false) ) ) {
	            Write-Verbose "Closing the runspace pool"
			    $runspacepool.close()
            }
            [gc]::Collect()
        }       
    }
} 
## End of Import-Parallel code ##
 


<# There was a maximum bandwidth limitation at each station. 
   CSV was listed sequentially by each station. Therefore, it was not optimal to copy files station by station.
   Randomized the list, to download from many stations, in order to improve total download speed. #>
$csv1 = get-random -inputobject (import-csv -path $csvpath) -Count 9999 | Where-Object -FilterScript {$_.Type -eq "Vendor" -or $_.Type -eq "Validator"}
$csv2 = get-random -inputobject (import-csv -path $csvpath) -Count 9999 | Where-Object -FilterScript {$_.Type -eq "POS"}



## Pre-making the directories are required for pulling files the first time and/or for new devices added to the system ##

function makeDirectory {

    foreach ($i in (import-csv -Path $Csvpath))   
    {

        If ($i.("Type") -eq "Vendor" -or $i.("Type") -eq "Validator")
        {
        
            mkdir -Force ($Storage + "\" + $i.("Type") + "\" + $i.("DeviceName")) | Out-Null
                        
        }
    
        Elseif ($i.("Type") -eq "POS")
        {
                                
            mkdir -Force ($Storage + "\POS\" + $i.("DeviceName") + "\POS\Logs") | Out-Null
            mkdir -Force ($Storage + "\POS\" + $i.("DeviceName") + "\Program Files\POS\Logs") | Out-Null
            mkdir -Force ($Storage + "\POS\" + $i.("DeviceName") + "\BankSoftware\Log") | Out-Null
                   
        }
    }
}


## Set variable $Parameters ##

$Parameters = @{storage = $storage; password = $password}


## Edit the -Throttle to set the number of maximum devices to download from at a time. I have it set to 15.

function pullFromPrimary {

    $csv1 | Invoke-Parallel -Throttle 15 -Parameter $Parameters -Logfile $parallelLog -ScriptBlock {
        $retry = $true
        $retriesleft = 3
        do {
            Try 
            {
                ## Copy all files where date = currentdate - 1 day (Files created yesterday) ##
                $n = $_
                $ErrorActionPreference = "Stop"
                net use ("\\" + $_.IPAddress) /user:Administrator $Parameter.password | Out-Null; 
                Get-ChildItem -Path ("\\" + $_.IPAddress + "\C$\Program Files\Example\Logs") | where-object -FilterScript {$_.creationtime.ToShortDateString() -eq (get-date).AddDays(-1).ToShortDateString()} | copy-item -destination ($Parameter.storage + "\" + $_.Type + "\" + $_.DeviceName);
                $retry = $false
	    
            }
            
            Catch
            {
	        If ($retriesleft -lt 1)
	        {
                ## Avoid multiple threads writing to the Exception file at the same time ##
            	    $mutex = New-Object System.Threading.Mutex($false,'mutexlog')
            	    [void]$mutex.WaitOne()
            	    "[" + (Get-Date) + "] Failed retrieving logs from: " + $n.DeviceName + " on " + $n.IPAddress | Out-File ($Parameter.storage + "\" + (Get-Date).ToString("yyyy.MM.dd") + "_Exceptions.txt") -append   
            	    $mutex.ReleaseMutex()
            	    $mutex.Dispose() 
		    $retry = $false
                }
	        Else
	        {
	    	    $retriesleft -= 1
		    Start-Sleep 15
	        }    
            }
            
            Finally
            {

                $ErrorActionPreference = "Continue"
            
            }
	}
	While ($retry -eq $true)
	net use ("\\" + $_.IPAddress) /delete
    }
}

<# Another function to pull log files which had different file structure from the first
   Edit the -Throttle to set the number of maximum devices to download from at a time. I have it set to 15. #>

function pullFromSecondary {

    $csv2 | Invoke-Parallel -Throttle 15 -Parameter $Parameters -Logfile $parallelLog -ScriptBlock {
        $retry = $true
        $retriesleft = 3
        Do {
	 
            Try
            {
            
                ## Copy all files where date = currentdate - 1 day (Files created yesterday) ##
                $n = $_
                $ErrorActionPreference = "Stop"
                net use ("\\" + $_.IPAddress) /user:Administrator $Parameters.password | Out-Null;
                Get-Childitem ("\\" + $_.IPAddress + "\C$\POS\Logs") | where-object {$_.creationtime.ToShortDateString() -eq (get-date).AddDays(-1).ToShortDateString()} | copy-item -destination ($Parameter.storage + "\POS\" + $_.DeviceName + "\POS\Logs\");
	        Get-Childitem ("\\" + $_.IPAddress + "\C$\Program Files\POS\Logs") | where-object {$_.creationtime.ToShortDateString() -eq (get-date).AddDays(-1).ToShortDateString()} | copy-item -destination ($Parameter.storage + "\TVM\" + $_.DeviceName + "\Program Files\POS\Logs");
	        Get-Childitem ("\\" + $_.IPAddress + "\C$\BankSoftware\Log") | where-object {$_.creationtime.ToShortDateString() -eq (get-date).AddDays(-1).ToShortDateString()} | copy-item -destination ($Parameter.storage + "\POS\" + $_.DeviceName + "\BankSoftware\Log");
                $retry = $false

            }

            Catch
            {
	        If ($retriesleft -lt 1)
	        {
                    ## Avoid multiple threads writing to the Exception file at the same time ##
                    $mutex = New-Object System.Threading.Mutex($false,'mutexlog')
                    [void]$mutex.waitOne()
                    "[" + (Get-Date) + "] Failed retrieving logs from: " + $n.IPAddress + " (" + $n.DeviceName + ")." | Out-File ($Parameter.storage + "\" + (Get-Date).ToString("yyyy.MM.dd") + "_Exceptions.txt") -append
                    $mutex.ReleaseMutex()
                    $mutex.Dispose()
	            $retry = $false
		}
	        Else
	        {
	    
	            $retriesleft -= 1
		    Start-Sleep 15
		
	        }
            }

            Finally
            {

                $ErrorActionPreference = "Continue"

            }
	}
	While ($retry -eq $true)
	net use ("\\" + $_.IPAddress) /delete
    }
}

## Run this Script

MakeDirectory

pullFromPrimary

pullFromSecondary
