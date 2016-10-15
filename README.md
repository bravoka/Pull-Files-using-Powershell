# Pull Files using Powershell

I needed a simple automated method of pulling log files from around 1000 devices each night. Feel free to use it as a template or reference for your own project. It had to download roughly 20 MB of log files a day. It utilizes the Invoke-Parallel cmdlet for Runspaces to speed up the process.

Some notes for why I did things this way include:

Our production DNS server was missing half the entries, and many were incorrect. Still waiting for someone to update it. I'd love to go in and fix it, but non-administrators don't have access :( 

I manually created a CSV file that linked Computer Name with IP addresses, as well as other information so that I can re-use this CSV for other functions in the future.

All production devices shared the same C$ password, so I conveniently used that.

I needed a logfile showing which devices it tried but failed to pull logs from. 
