# Contributing to AD Health Check

Thank you for your interest in contributing to AD Health Check! This document provides guidelines and instructions for contributing.

## 🎯 **How Can I Contribute?**

### **1. Report Bugs**
- Use GitHub Issues
- Include PowerShell version, OS version, AD environment details
- Provide error messages and logs
- Steps to reproduce

### **2. Suggest Features**
- Check existing issues first
- Describe the use case
- Explain the expected behavior
- Consider impact on existing checks

### **3. Add New Checks**
- Follow the check template structure
- Include comprehensive error handling
- Add evaluation rules in JSON
- Document remediation steps
- Reference Microsoft KB articles

### **4. Improve Documentation**
- Fix typos and grammar
- Add examples
- Clarify complex sections
- Translate to other languages

---

## 📝 **Development Guidelines**

### **Code Style**

**PowerShell:**
```powershell
# ✅ GOOD - PascalCase for functions
function Get-ADHealthStatus { }

# ✅ GOOD - Descriptive variable names
$domainController = "DC01.contoso.com"

# ✅ GOOD - Comment-based help
<#
.SYNOPSIS
    Brief description
.DESCRIPTION
    Detailed description
#>

# ❌ BAD - Unclear names
$dc = "DC01"
$x = Get-Something
```

**All Code:**
- ✅ Write in English (code, comments, variables)
- ✅ Use descriptive names
- ✅ Include error handling (try/catch)
- ✅ Add inline comments for complex logic
- ✅ Follow existing patterns

### **Check Script Template**

```powershell
<#
.SYNOPSIS
    [Check Name] ([CHECK-ID])

.DESCRIPTION
    [Detailed description of what this checks]

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-YourCheck.ps1 -Inventory $inventory

.OUTPUTS
    Array of check result objects

.NOTES
    Check ID: [CHECK-ID]
    Category: [Category]
    Severity: [Critical/High/Medium/Low]
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[[CHECK-ID]] Starting check..."

try {
    # Your check logic here
    
    # Return structured results
    $result = [PSCustomObject]@{
        PropertyName = $value
        Status = 'Healthy'  # or 'Failed', 'Warning'
        IsHealthy = $true
        HasIssue = $false
        Message = "Description"
    }
    
    $results += $result
    
    return $results
}
catch {
    Write-Error "[[CHECK-ID]] Check failed: $($_.Exception.Message)"
    
    return @([PSCustomObject]@{
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $($_.Exception.Message)"
    })
}
```

### **Check Definition Template (JSON)**

```json
{
  "CheckId": "CAT-NNN",
  "CheckName": "Descriptive Name",
  "CategoryId": "Category",
  "Description": "What this checks and why it matters",
  "Severity": "Critical|High|Medium|Low",
  "Impact": "What happens if this fails",
  "Probability": "How likely this is to occur",
  "Effort": "How hard to fix",
  "ScriptPath": "../Checks/Category/Test-CheckName.ps1",
  "EvaluationRules": {
    "Rules": [
      {
        "Condition": "Expression to evaluate",
        "Status": "Pass|Warning|Fail",
        "Title": "Issue title",
        "Description": "Issue description"
      }
    ]
  },
  "RemediationSteps": "Step-by-step fix instructions",
  "KBArticles": [
    "https://docs.microsoft.com/..."
  ],
  "Tags": ["Tag1", "Tag2"],
  "IsEnabled": true,
  "Version": "1.0"
}
```

---

## 🔄 **Pull Request Process**

### **1. Fork and Clone**
```bash
# Fork on GitHub, then:
git clone https://github.com/YOUR_USERNAME/ADHealthCheck.git
cd ADHealthCheck
```

### **2. Create Branch**
```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/bug-description
```

### **3. Make Changes**
- Write code following guidelines
- Test thoroughly in AD environment
- Update documentation if needed

### **4. Test Your Changes**
```powershell
# Test database
.\Tests\Test-Database.ps1

# Test your check
. .\Checks\YourCategory\Test-YourCheck.ps1
$inventory = Invoke-ADDiscovery
Test-YourCheck -Inventory $inventory

# Test full execution
.\Invoke-ADHealthCheck.ps1 -Categories YourCategory -LogLevel Verbose
```

### **5. Commit**
```bash
git add .
git commit -m "Add: Brief description of changes"

# Commit message format:
# Add: New feature
# Fix: Bug fix
# Update: Changes to existing code
# Docs: Documentation only
```

### **6. Push and Create PR**
```bash
git push origin feature/your-feature-name
```

Then create Pull Request on GitHub.

---

## ✅ **PR Checklist**

- [ ] Code follows project style guidelines
- [ ] All code is in English
- [ ] Added/updated documentation
- [ ] Tested in real AD environment
- [ ] No hardcoded credentials or sensitive data
- [ ] Error handling included
- [ ] Check includes evaluation rules (if applicable)
- [ ] KB article references included (if applicable)

---

## 🐛 **Bug Report Template**

```markdown
**Description**
Clear description of the bug

**Environment**
- PowerShell Version: 
- OS Version: 
- AD Forest Functional Level: 
- Number of DCs: 

**Steps to Reproduce**
1. Run command...
2. See error...

**Expected Behavior**
What should happen

**Actual Behavior**
What actually happened

**Logs**
```
Paste relevant log output
```

**Screenshots**
If applicable
```

---

## 💡 **Feature Request Template**

```markdown
**Feature Description**
Clear description of the feature

**Use Case**
Why is this needed?

**Proposed Solution**
How should it work?

**Alternatives Considered**
Other approaches you've thought about

**Additional Context**
Any other relevant information
```

---

## 📋 **Current Priorities**

### **High Priority**
1. Complete remaining 8 critical check scripts (Step 4)
2. Enhanced HTML report templates
3. Full engine-database integration
4. More comprehensive error handling

### **Medium Priority**
1. Additional replication checks
2. GPO validation checks
3. Security baseline checks
4. Performance optimization

### **Future**
1. Web-based UI (React/Blazor)
2. Scheduled execution support
3. Email notifications
4. Trend analysis and dashboards

---

## 📞 **Questions?**

- Open a [GitHub Discussion](https://github.com/YOUR_USERNAME/ADHealthCheck/discussions)
- Check existing [Issues](https://github.com/YOUR_USERNAME/ADHealthCheck/issues)

---

**Thank you for contributing to AD Health Check!** 🎉
