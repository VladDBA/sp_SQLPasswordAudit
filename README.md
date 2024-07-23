# sp_SQLPasswordAudit
<a name="header1"></a>

## Navigation
- [About](#About)

- [Features](#Features)

- [Limitations](#Limitations)

- [Setting up](#Setting-up)

- [Usage examples](#Usage-examples)


## About
sp_SQLPasswordAudit is a stored procedure that checks the passwords of your existing SQL Logins against
popular password lists, as well as auto-generated instance-specific passwords using common password paterns 
and custom terms (e.g. the name of a company, the name of an internal project, etc.).
This stored procedure has been designed for auditing SQL login passwords in hopes of identifying and correcting 
weak passwords.

## Features
* Helps identify SQL Server logins with weak passwords
* Uses [password lists](/PasswordLists) from known breaches and campaigns ([rockyou](https://techcrunch.com/2009/12/14/rockyou-hack-security-myspace-facebook-passwords/), [nansh0u](https://www.guardicore.com/2019/05/nansh0u-campaign-hackers-arsenal-grows-stronger/)) commonly used by hackers for both brute forcing and password spraying attacks.
* Since the stored procedure relies SQL Server's built-in [PWDCOMPARE](https://docs.microsoft.com/en-us/sql/t-sql/functions/pwdcompare-transact-sql?view=sql-server-ver15), it is able to check a large number of passwords against a login
 without the risk of locking it out.
* The password lists in .sql format have been cleaned-up and are all set to be inserted in the Passwords table via a simple sqlcmd command.
* Experimental: sp_SQLPasswordAudit is also able to auto-generate possible passwords based on information already
 available on the instance like:
  - database names and creation dates
  - login names and creation dates
  - instance name 
  - instance creation date
  And combines them with
  - current year as well as the three previous years
  - common password patterns (l33t replacements, symbols, concatenations between terms, etc.)
  The auto-generated passwords can also use the custom term provided via the @CustomTerm parameter, 
  this can be anything ranging from the name of the company or the name of an internal project to any other 
  string that might have been used in the composition of a password.
 * Can output the findings to a permanent table.

[*Back to top*](#header1)

## Limitations
 * sp_SQLPasswordAudit has been built for and tested on SQL Server 2012 through 2022, there is no guarantee that it will work as expected on older versions of SQL Server.
 * When running on an instance with many databases and logins with the @UseInstanceInfo parameter set to 1, the quasi-temporary table used to store the auto-generated passwords could grow to 1-2GB in size, it is recommended that you pre-grow in advance the database that hosts the stored procedure.
 * Running sp_SQLPasswordAudit against large password lists such as [rockyou](/PasswordLists/rockyou.zip) will cause [PREEMPTIVE_OS_CRYPTOPS waits](https://www.sqlskills.com/help/waits/preemptive_os_cryptops/) that can be picked by [Brent Ozar](https://www.brentozar.com/)'s [SQL Server First Responder Kit](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit) (sp_BlitzWho and sp_BlitzCache in particular) and/or by various monitoring tools that capture high waits.
 
[*Back to top*](#header1)

## Setting up
* It is highly recommended to create sp_SQLPasswordAudit and the [Passwords table](/PasswordLists/CreatePasswordsTable.sql) in a database that is not used by end-user applications and that can be pre-grwon by a few GB.
1. Create the [Passwords table](/PasswordLists/CreatePasswordsTable.sql) using the provided script
2. Create the [sp_SQLPasswordAudit](sp_SQLPasswordAudit.sql) stored procedure 
3. Download the password lists from [here](/PasswordLists)
4. Using command prompt, run the following command updated to match your environment and the list name you want to add to the Passwords table:
  - if you're using trusted connection (aka an AD account) to connect to the instance:
```
sqlcmd -S HostName\Instance -E -d TargetDatabase -x -i PathToList\ListScript.sql -o PathToOutputFile\insertout.txt
```
  - if you're using a SQL login to connect to the instance:
```
sqlcmd -S HostName\Instance -U LoginName -P LoginPassword -d TargetDatabase -x -i PathToList\ListScript.sql -o PathToOutputFile\insertout.txt
```
>*Note1: while password lists under 10MB can be inserted in the table using SSMS, larger lists, such as rockyou can only be loaded using sqlcmd via Command Prompt. Aso, password insert scripts larger than 10MB will be zipped.

>*Note2: the -x option is required to tell sqlcmd to not consider strings containing the dollar sign ($) as scripting variables and not try to expand them. Not using the -x option will result in the insert failing when the first string from a password list containing a $ is encountered.

[*Back to top*](#header1)

## Parameter explanations
| Parameter| Effect | Possible values | Default value |
|----------|--------|-----------------|---------------|
|	@Help | Prints information about the procedure and a short help menu| 1 or 0 | 0 |
| @ExcludeDisabled | Used to specify whether logins marked as disabled should be skipped or not| 1 or 0| 1 (yes)|
| @IgnorePolicy | Specifies whether or not passwords shorter than 8 characters should be checked against hashes of logins where is_policy_checked is set to 1. | 1 or 0 | 0 (check passwords < 8 characters only against logins having is_policy_checked= 0)|
| @ResultsToTable | specifies wether or not the results of the check should be saved in a permanent table (the table is created by the stored procedure and is called SQLAuditResults) | 1 or 0| 0 (No) |
| @SourceLists | Name(s) of the source list(s), comma separated, that should be checked against (e.g. rockyou, nansh0u, etc.), based on the ones existing in the Passwords table. If you plan on only using instance-specific auto-generated passwords, provide a name that doesn't exist (e.g. nolist).| multiple | ALL |
| @UseInstanceInfo |Specifies wheter or not the stored procedure should auto generate instance-specific passwords and includem them in the check. | 1 or 0 | 0 (No)|
| @CustomTerm | Used to pass a single custom term (name of the company, name of a project, name of a vendor, etc.) based on which the procedure should auto generate possible passwords | pretty much anything relevant | '' (empty string)

[*Back to top*](#header1)

## Usage examples
```SQL
EXECUTE sp_SQLPasswordAudit;
```
Will run the stored procedure with it's default settings:
  * Check against all the passwords in the Passwords table
  * Excludes logins that are not enabled
  * Only checks passwords shorter than 8 characters against the hashes of logins that have is_policy_checked set to 0
  * Will output the results to grid without storing them in a permanent table
  * Will not use instance-related information in generating passwords
  * Won't generate password candidates based on a custom term
```SQL
EXECUTE sp_SQLPasswordAudit @SourceLists     = 'nansh0u', 
                            @ExcludeDisabled = 0, 
                            @ResultsToTable  = 1,
                            @CustomTerm      = 'MyCompany';
```  
Will have the following behaviour:
 * It will only check against the passwords from the nansh0u list
 * It will not exclude logins that are not currently enabled
 * Saves the results to a permanent table called SQLAuditResults 
 * Generates possible passwords based on the MyCompany string and checks the hashes against them as well
```SQL
EXECUTE sp_SQLPasswordAudit @SourceLists      = 'rockyou, nansh0u', 
                            @ExcludeDisabled  = 0,
                            @IgnorePolicy     = 1, 
                            @ResultsToTable   = 1,
                            @UseInstanceInfo  = 1,
                            @CustomTerm       = 'MyCompany';
```  
Will have the following behaviour:
 * Checks against passwords from both rockyou and nansh0u lists
 * Checks against passwords that are currently not enabled
 * Checks passwords shorter than 8 characters against all logins, regardless of is_policy_checked
 * Saves the results to a permanent table called SQLAuditResults 
 * Checks the hashes against auto generated instance-specific passwords
 * Generates possible passwords based on the MyCompany string and checks the hashes against them as well
```SQL
EXECUTE sp_SQLPasswordAudit @SourceLists      = 'nolist',
                            @ResultsToTable   = 1,
                            @UseInstanceInfo  = 1,
                            @CustomTerm       = 'MyCompany';
``` 
Will have the following behaviour:
 * Does not use any of the passwords in the Passwords table
 * Saves the result to the SQLAuditResults table
 * Checks the hashes against auto generated instance-specific passwords
 * Generates possible passwords based on the MyCompany string and checks the hashes against them as well

 [*Back to top*](#header1)
