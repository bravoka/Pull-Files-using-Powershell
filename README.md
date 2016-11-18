# Pull Files using Powershell

I wrote a simple automated script to pull log files from around 1000 devices each night. It is used to download roughly 20 MB of log files from each device that were generated the previous day. It utilizes the Invoke-Parallel cmdlet for Runspaces to speed up the process.

Folder names and CSV values were modified for the examples. It is quite situation specific, but is posted here intended to be used as a general project structure or template for your own project.



Some notes for why I did things this way include:

Goal while writing this Powershell script include designing it so that others could easily modify script variables or make minor changes without knowing Powershell.

Our production DNS server was missing half the entries, and some were incorrect or IPs had been changed. Still waiting for someone to update it. I'd love to go in and fix it, but non-administrators don't have access...

I manually created a CSV file that linked Computer Name with IP addresses, as well as other information so that I can re-use this CSV for other functions in the future.

All production devices shared the same C$ password, so I conveniently used that.

I needed a logfile showing which devices it tried but failed to pull logs from. 

17 November 2016 Update:
------------------------
- Added retries in each loop in case of connection interruption due to less than perfect network
