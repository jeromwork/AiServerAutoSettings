# Explicit project selection. No transport is started by this module.
function Format-RemoteSyncProjectBytes([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} ГБ' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} МБ' -f ($Bytes / 1MB)) }
    return ('{0:N0} КБ' -f ($Bytes / 1KB))
}
function New-RemoteSyncProjectSelectionForm {
    param([object[]]$Candidates=@(), [string]$DataDir, [string]$HostId)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form=New-Object Windows.Forms.Form
    $form.Text='Выберите проекты'; $form.StartPosition='CenterScreen'
    $form.Size=New-Object Drawing.Size(1120,650);$form.MinimumSize=New-Object Drawing.Size(850,550)
    $form.Font=New-Object Drawing.Font('Segoe UI',9)
    $layout=New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock='Fill';$layout.ColumnCount=1;$layout.RowCount=5
    foreach($height in @(64,90,38)){[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$height)))}
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,55)))
    $form.Controls.Add($layout)
    $intro=New-Object Windows.Forms.Label
    $intro.Text="Вставьте пути по одному на строку или выберите папку.`r`nОтметьте нужные проекты. Новые папки не выбраны.`r`nИсходные папки не изменяются. Перенос начнётся после сохранения выбора."
    $intro.Dock='Fill';$intro.Padding=New-Object Windows.Forms.Padding(8)
    $layout.Controls.Add($intro,0,0)
    $inputPanel=New-Object Windows.Forms.TableLayoutPanel
    $inputPanel.Dock='Fill';$inputPanel.ColumnCount=2
    [void]$inputPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
    [void]$inputPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,165)))
    $paths=New-Object Windows.Forms.TextBox
    $paths.Multiline=$true;$paths.ScrollBars='Vertical';$paths.Dock='Fill'
    $paths.AccessibleName='Пути папок: по одному на строку';$paths.AcceptsReturn=$true
    $inputPanel.Controls.Add($paths,0,0)
    $add=New-Object Windows.Forms.Button;$add.Text='Добавить список';$add.Dock='Fill'
    $inputPanel.Controls.Add($add,1,0);$layout.Controls.Add($inputPanel,0,1)
    $tools=New-Object Windows.Forms.FlowLayoutPanel;$tools.Dock='Fill'
    $browse=New-Object Windows.Forms.Button;$browse.Text='Выбрать папку…';$browse.AutoSize=$true
    $find=New-Object Windows.Forms.Button;$find.Text='Найти проекты…';$find.AutoSize=$true
    $drive=New-Object Windows.Forms.Button;$drive.Text='Поиск на диске…';$drive.AutoSize=$true
    $nonGit=New-Object Windows.Forms.CheckBox;$nonGit.Text='Искать и без Git';$nonGit.AutoSize=$true;$nonGit.Padding=New-Object Windows.Forms.Padding(4,6,0,0)
    $tools.Controls.AddRange(@($browse,$find,$drive,$nonGit));$layout.Controls.Add($tools,0,2)
    $browse.MinimumSize=New-Object Drawing.Size(145,28);$find.MinimumSize=New-Object Drawing.Size(145,28);$drive.MinimumSize=New-Object Drawing.Size(145,28)
    $list=New-Object Windows.Forms.ListView
    $list.View='Details';$list.CheckBoxes=$true;$list.FullRowSelect=$true;$list.GridLines=$true;$list.Dock='Fill';$list.HideSelection=$false;$list.ShowItemToolTips=$true
    foreach($column in @(@('Проект',155),@('Тип',85),@('Изменён',130),@('Объём ≈',85),@('Файлов',65),@('Оценка',220),@('Папка',330))){[void]$list.Columns.Add($column[0],[int]$column[1])}
    $layout.Controls.Add($list,0,3)
    $bottom=New-Object Windows.Forms.TableLayoutPanel;$bottom.Dock='Fill';$bottom.ColumnCount=3
    [void]$bottom.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
    [void]$bottom.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,145)))
    [void]$bottom.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,115)))
    $status=New-Object Windows.Forms.Label;$status.Text='Секреты, зависимости и сборки исключены. Галочка = подключать.';$status.Dock='Fill';$status.Padding=New-Object Windows.Forms.Padding(7)
    $save=New-Object Windows.Forms.Button;$save.Text='Сохранить и начать';$save.Dock='Fill'
    $cancel=New-Object Windows.Forms.Button;$cancel.Text='Отмена';$cancel.Dock='Fill';$cancel.DialogResult='Cancel'
    $bottom.Controls.Add($status,0,0);$bottom.Controls.Add($save,1,0);$bottom.Controls.Add($cancel,2,0);$layout.Controls.Add($bottom,0,4)
    $form.CancelButton=$cancel
    $state=[pscustomobject]@{Form=$form;List=$list;Paths=$paths;Status=$status;Candidates=@($Candidates);DataDir=$DataDir;HostId=$HostId;Result=$null;NonGit=$nonGit;Save=$save;Add=$add;Find=$find;Browse=$browse;Drive=$drive}
    $render={
        $state.List.BeginUpdate()
        try{
            foreach($item in $state.List.Items){$item.Tag.selected=[bool]$item.Checked}
            $state.Candidates=@($state.Candidates|Sort-Object @{Expression={if($_.inventory.lastSourceWriteUtc){[datetime]$_.inventory.lastSourceWriteUtc}else{[datetime]::MinValue}};Descending=$true},sourcePath)
            $state.List.Items.Clear()
            foreach($candidate in $state.Candidates){
                $inventory=$candidate.inventory;$name=[IO.Path]::GetFileName($candidate.sourcePath.TrimEnd('\','/'))
                $item=New-Object Windows.Forms.ListViewItem($name)
                $kind=switch($candidate.kind){'worktree'{'Ворктри'}'git'{'Git'}default{'Папка'}}
                [void]$item.SubItems.Add($kind)
                $date=if($inventory.lastSourceWriteUtc){([datetime]$inventory.lastSourceWriteUtc).ToLocalTime().ToString('dd.MM.yyyy HH:mm')}else{'нет исходников'}
                [void]$item.SubItems.Add($date);[void]$item.SubItems.Add((Format-RemoteSyncProjectBytes $inventory.bytes));[void]$item.SubItems.Add([string]$inventory.fileCount)
                $details=if($inventory.complete){'Готово'}else{'Неполная оценка'}
                if($inventory.excludedCount){$details+='; исключено: '+$inventory.excludedCount}
                if($inventory.largeFileCount){$details+='; крупных: '+$inventory.largeFileCount}
                [void]$item.SubItems.Add($details);[void]$item.SubItems.Add($candidate.sourcePath)
                $item.Tag=$candidate;$item.Checked=[bool]$candidate.selected
                $item.ToolTipText='Объём и дата — по разрешённым исходникам. Секреты, зависимости, сборки и ссылки исключены. Крупные файлы учтены в оценке.'
                if(!$inventory.complete){$item.ToolTipText+=' Оценка неполная: '+($inventory.reasons -join ', ')}
                [void]$state.List.Items.Add($item)
            }
        }finally{$state.List.EndUpdate()}
    }.GetNewClosure()
    $append={param([string[]]$NewPaths)
        foreach($item in $state.List.Items){$item.Tag.selected=[bool]$item.Checked}
        $new=@(Get-RemoteSyncProjectCandidates -Paths $NewPaths -DataDir $state.DataDir -HostId $state.HostId)
        foreach($candidate in $new){if(-not @($state.Candidates|Where-Object{[string]::Equals($_.sourcePath,$candidate.sourcePath,[StringComparison]::OrdinalIgnoreCase)}).Count){$state.Candidates+=,$candidate}}
        & $render
    }.GetNewClosure()
    $showError={param($message)[void][Windows.Forms.MessageBox]::Show($state.Form,[string]$message,'Папка не добавлена','OK','Warning')}.GetNewClosure()
    $add.Add_Click({try{& $append (ConvertFrom-RemoteSyncProjectPaths -Text $state.Paths.Text);$state.Paths.Clear()}catch{& $showError $_.Exception.Message}}.GetNewClosure())
    $browse.Add_Click({
        $picker=New-Object Windows.Forms.FolderBrowserDialog;$picker.Description='Выберите папку одного проекта';$picker.ShowNewFolderButton=$false
        try{if($picker.ShowDialog($state.Form) -eq 'OK'){try{& $append @($picker.SelectedPath)}catch{& $showError $_.Exception.Message}}}finally{$picker.Dispose()}
    }.GetNewClosure())
    $discover={param([bool]$OnDrive)
        $picker=New-Object Windows.Forms.FolderBrowserDialog;$picker.ShowNewFolderButton=$false
        $picker.Description=if($OnDrive){'Явно выберите диск для ограниченного поиска'}else{'Где искать проекты?'}
        try{
            if($picker.ShowDialog($state.Form) -ne 'OK'){return}
            if($OnDrive -and [Windows.Forms.MessageBox]::Show($state.Form,'Искать на выбранном диске? Личные и системные папки будут пропущены.','Поиск на диске','YesNo','Question') -ne 'Yes'){return}
            $state.Form.UseWaitCursor=$true;$state.Status.Text='Ищем проекты. Найденные папки не будут выбраны автоматически.';$state.Form.Refresh()
            $arguments=@{RootPath=$picker.SelectedPath;IncludeNonGit=[bool]$state.NonGit.Checked}
            if($OnDrive){$arguments.AllowVolumeRoot=$true}
            $found=Find-RemoteSyncProjectCandidates @arguments
            $foundPaths=@($found.candidates|ForEach-Object{$_.sourcePath})
            if($foundPaths.Count){& $append $foundPaths}
            $state.Status.Text=if($found.complete){'Найдено: '+$foundPaths.Count+'. Отметьте нужные проекты.'}else{'Поиск неполный. Найдено: '+$foundPaths.Count+'. Можно искать в более узкой папке.'}
        }catch{& $showError $_.Exception.Message}finally{$state.Form.UseWaitCursor=$false;$picker.Dispose()}
    }.GetNewClosure()
    $find.Add_Click({& $discover $false}.GetNewClosure());$drive.Add_Click({& $discover $true}.GetNewClosure())
    $save.Add_Click({
        try{
            foreach($item in $state.List.Items){$item.Tag.selected=[bool]$item.Checked}
            $state.Result=Save-RemoteSyncSelection -DataDir $state.DataDir -HostId $state.HostId -Candidates $state.Candidates
            $state.Form.DialogResult='OK';$state.Form.Close()
        }catch{& $showError $_.Exception.Message}
    }.GetNewClosure())
    & $render
    return $state
}
function Show-RemoteSyncConsoleSelection {
    param([object[]]$Candidates=@(),[string]$DataDir,[string]$HostId)
    while($true){
        Write-Host 'Выберите проекты. Новые папки не подключаются автоматически.'
        for($i=0;$i -lt $Candidates.Count;$i++){$mark=if($Candidates[$i].selected){'+'}else{' '};Write-Host (($i+1).ToString()+'. ['+$mark+'] '+$Candidates[$i].sourcePath)}
        Write-Host 'A — добавить пути; S — сохранить; 0 — отмена. Номера через запятую меняют галочки.'
        $choice=(Read-Host 'Выбор').Trim()
        if($choice -eq '0' -or !$choice){return [pscustomobject]@{cancelled=$true;selection=$null}}
        if($choice -match '^[sSыЫ]$'){
            try{$result=Save-RemoteSyncSelection -DataDir $DataDir -HostId $HostId -Candidates $Candidates;return [pscustomobject]@{cancelled=$false;selection=$result}}catch{Write-Host $_.Exception.Message;continue}
        }
        if($choice -match '^[aAфФ]$'){
            Write-Host 'Вставляйте пути по одному. Пустая строка завершает список.'
            $lines=New-Object 'Collections.Generic.List[string]'
            do{$line=Read-Host 'Папка';if($line){$lines.Add($line)}}while($line)
            try{
                $new=@(Get-RemoteSyncProjectCandidates -Paths (ConvertFrom-RemoteSyncProjectPaths -Text ($lines -join "`n")) -DataDir $DataDir -HostId $HostId)
                foreach($candidate in $new){if(-not @($Candidates|Where-Object{[string]::Equals($_.sourcePath,$candidate.sourcePath,[StringComparison]::OrdinalIgnoreCase)}).Count){$Candidates+=,$candidate}}
            }catch{Write-Host $_.Exception.Message};continue
        }
        $numbers=@($choice.Split(',')|ForEach-Object{$_.Trim()});$valid=$true
        foreach($number in $numbers){if($number -notmatch '^\d+$' -or [int]$number -lt 1 -or [int]$number -gt $Candidates.Count){$valid=$false}}
        if(!$valid){Write-Host 'Введите номера из списка.';continue}
        foreach($number in ($numbers|Select-Object -Unique)){$Candidates[[int]$number-1].selected=-not $Candidates[[int]$number-1].selected}
    }
}
function Show-RemoteSyncProjectSelection {
    param([string]$DataDir,[string]$HostId,[switch]$Console)
    $saved=Get-RemoteSyncSelection -DataDir $DataDir -HostId $HostId
    $candidates=@()
    foreach($entry in $saved.projects){
        try{$candidates+=@(Get-RemoteSyncProjectCandidates -Paths @($entry.sourcePath) -DataDir $DataDir -HostId $HostId)}
        catch{
            $candidates+=,[pscustomobject]@{sourcePath=$entry.sourcePath;projectId=$entry.projectId;scopeMode=$entry.scopeMode;kind='folder';selected=[bool]$entry.selected;inventory=[pscustomobject]@{lastSourceWriteUtc=$null;bytes=0;fileCount=0;complete=$false;reasons=@('Папка недоступна');largeFileCount=0;excludedCount=0}}
            Write-Host ('Папка временно недоступна: '+$entry.sourcePath+'. Верните доступ или снимите галочку.')
        }
    }
    $canShow=(-not $Console -and [Environment]::UserInteractive -and [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')
    if($canShow){
        try{$state=New-RemoteSyncProjectSelectionForm -Candidates $candidates -DataDir $DataDir -HostId $HostId}
        catch{Write-Host 'Окно недоступно. Выберите проекты в консоли.';$canShow=$false}
    }
    if(!$canShow){return Show-RemoteSyncConsoleSelection -Candidates $candidates -DataDir $DataDir -HostId $HostId}
    try{
        if($state.Form.ShowDialog() -ne 'OK'){return [pscustomobject]@{cancelled=$true;selection=$null}}
        return [pscustomobject]@{cancelled=$false;selection=$state.Result}
    }finally{$state.Form.Dispose()}
}
