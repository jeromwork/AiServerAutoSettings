# Explicit project selection. No transport is started by this module.
function Format-RemoteSyncProjectBytes([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} ГБ' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} МБ' -f ($Bytes / 1MB)) }
    return ('{0:N0} КБ' -f ($Bytes / 1KB))
}
function Merge-RemoteSyncProjectCandidates {
    param([object[]]$Existing=@(),[object[]]$Found=@())
    $rows=New-Object 'Collections.Generic.List[object]';$seen=@{}
    foreach($candidate in @($Existing)+@($Found)){
        $key=[IO.Path]::GetFullPath($candidate.sourcePath).TrimEnd('\')
        if(!$seen.ContainsKey($key)){$seen[$key]=$candidate;$rows.Add($candidate)}
        elseif($seen[$key] -ne $candidate){
            $existingRow=$seen[$key]
            if($candidate.inventory.complete -or !$existingRow.inventory.complete){$existingRow.inventory=$candidate.inventory;$existingRow.kind=$candidate.kind}
        }
    }
    @($rows|Sort-Object @{Expression={if($_.kind -eq 'worktree'){1}else{0}}},@{Expression={if($_.inventory.lastSourceWriteUtc){[datetime]$_.inventory.lastSourceWriteUtc}else{[datetime]::MinValue}};Descending=$true},sourcePath)
}
function Initialize-RemoteSyncConsoleMouse {
    if([Console]::IsInputRedirected -or [Console]::IsOutputRedirected){return $false}
    try{
        if(!('RemoteAgentsProjectConsole' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'project-console-input.cs')}
        return [RemoteAgentsProjectConsole]::Available
    }catch{return $false}
}
function Read-RemoteSyncConsoleChoice($Rows,[bool]$Mouse) {
    if($Mouse){
        Write-Host 'Выбор: ' -NoNewline
        try{return [RemoteAgentsProjectConsole]::Read($Rows)}catch{Write-Host 'Введите выбор с клавиатуры.'}
    }
    return Read-Host 'Выбор'
}
function Format-RemoteSyncQuickSearchStatus($Found) {
    if($Found.reasons -contains 'git-unavailable'){return 'Git пока не подготовлен. Добавьте папку вручную: установщик подготовит служебный Git.'}
    $message=if(@($Found.candidates).Count){'Найдено Git-репозиториев: '+@($Found.candidates).Count+'. Git выше worktree, свежие внутри группы. Отметьте нужные.'}else{'В указанных папках Git-репозитории не найдены. Нажмите F для поиска в другой папке или A для точного пути.'}
    if($Found.PSObject.Properties.Name -contains 'visitedDirectories'){$message+=' Проверено каталогов: '+$Found.visitedDirectories+'.'}
    if(!$Found.complete){$message+=' Поиск ограничен; другие папки можно указать вручную.'}
    return $message
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
    foreach($height in @(64,90,70)){[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$height)))}
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,55)))
    $form.Controls.Add($layout)
    $intro=New-Object Windows.Forms.Label
    $intro.Text="Нажмите «Быстро найти репозитории» или добавьте папки вручную.`r`nОтметьте нужные проекты. Новые папки не выбраны.`r`nИсходные папки не изменяются. Перенос начнётся после сохранения выбора."
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
    $quick=New-Object Windows.Forms.Button;$quick.Text='Быстро найти репозитории';$quick.AutoSize=$true;$quick.MinimumSize=New-Object Drawing.Size(215,28)
    $browse=New-Object Windows.Forms.Button;$browse.Text='Выбрать папку…';$browse.AutoSize=$true
    $find=New-Object Windows.Forms.Button;$find.Text='Найти проекты…';$find.AutoSize=$true
    $drive=New-Object Windows.Forms.Button;$drive.Text='Поиск на диске…';$drive.AutoSize=$true
    $nonGit=New-Object Windows.Forms.CheckBox;$nonGit.Text='Искать и без Git';$nonGit.AutoSize=$true;$nonGit.Padding=New-Object Windows.Forms.Padding(4,6,0,0)
    $tools.Controls.AddRange(@($quick,$browse,$find,$drive,$nonGit));$layout.Controls.Add($tools,0,2)
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
    $state=[pscustomobject]@{Form=$form;List=$list;Paths=$paths;Status=$status;Candidates=@($Candidates);DataDir=$DataDir;HostId=$HostId;Result=$null;NonGit=$nonGit;Save=$save;Add=$add;Find=$find;Browse=$browse;Drive=$drive;Quick=$quick}
    $render={
        $state.List.BeginUpdate()
        try{
            foreach($item in $state.List.Items){$item.Tag.selected=[bool]$item.Checked}
            $state.Candidates=@(Merge-RemoteSyncProjectCandidates -Existing $state.Candidates)
            $state.List.Items.Clear()
            foreach($candidate in $state.Candidates){
                $inventory=$candidate.inventory;$name=[IO.Path]::GetFileName($candidate.sourcePath.TrimEnd('\','/'))
                $item=New-Object Windows.Forms.ListViewItem($name)
                $kind=switch($candidate.kind){'subscription'{'С VPS'}'worktree'{'Ворктри'}'git'{'Git'}default{'Папка'}}
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
    $quick.Add_Click({
        try{
            $state.Quick.Enabled=$false;$state.Form.UseWaitCursor=$true
            $state.Status.Text='Быстро проверяем типичные папки с Git-репозиториями…';$state.Form.Refresh()
            foreach($item in $state.List.Items){$item.Tag.selected=[bool]$item.Checked}
            $found=Find-RemoteSyncQuickRepositories -DataDir $state.DataDir -HostId $state.HostId
            $state.Candidates=@(Merge-RemoteSyncProjectCandidates -Existing $state.Candidates -Found $found.candidates)
            & $render
            $state.Status.Text=Format-RemoteSyncQuickSearchStatus $found
        }catch{& $showError $_.Exception.Message}finally{$state.Form.UseWaitCursor=$false;$state.Quick.Enabled=$true}
    }.GetNewClosure())
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
    $Candidates=@(Merge-RemoteSyncProjectCandidates -Existing $Candidates)
    $page=0;$pageSize=10
    $selectedOnly=$false
    $searchPending=($Candidates.Count -eq 0)
    $mouse=Initialize-RemoteSyncConsoleMouse
    while($true){
        if($searchPending){
            $searchPending=$false
            Write-Host 'Ищем Git-репозитории в типичных папках. Обычно это занимает до 15 секунд…'
            try{
                $found=Find-RemoteSyncQuickRepositories -DataDir $DataDir -HostId $HostId
                $Candidates=@(Merge-RemoteSyncProjectCandidates -Existing $Candidates -Found $found.candidates)
                $page=0
                Write-Host (Format-RemoteSyncQuickSearchStatus $found)
            }catch{Write-Host ('Поиск не завершён: '+$_.Exception.Message)}
        }
        $visible=@(for($index=0;$index -lt $Candidates.Count;$index++){if(!$selectedOnly -or $Candidates[$index].selected){$index}})
        $pages=[Math]::Max(1,[int][Math]::Ceiling($visible.Count/[double]$pageSize));$page=[Math]::Min($page,$pages-1)
        $checked=@($Candidates|Where-Object{$_.selected}).Count
        Write-Host ''
        Write-Host ('=== Проекты: отмечено '+$checked+' из '+$Candidates.Count+'; страница '+($page+1)+'/'+$pages+' ===')
        if($selectedOnly){Write-Host 'Показаны только отмеченные папки. V — вернуться ко всем.'}
        Write-Host 'Git выше worktree; внутри группы — свежие исходники сверху. [+] — подключать.'
        $mouseRows=New-Object 'Collections.Generic.Dictionary[int,string]'
        for($position=$page*$pageSize;$position -lt [Math]::Min($visible.Count,($page+1)*$pageSize);$position++){
            $i=$visible[$position]
            $candidate=$Candidates[$i];$mark=if($candidate.selected){'+'}else{' '}
            $name=[IO.Path]::GetFileName($candidate.sourcePath.TrimEnd('\','/'))
            $kind=switch($candidate.kind){'git'{'Git'}'worktree'{'Worktree'}'subscription'{'С VPS'}default{'Папка'}}
            $date='не определена'
            if($candidate.inventory.lastSourceWriteUtc){$date=([datetime]$candidate.inventory.lastSourceWriteUtc).ToLocalTime().ToString('dd.MM.yyyy HH:mm')}
            $estimate=if($candidate.inventory.complete){''}else{' (~ неполная оценка)'}
            $row=('{0,3}. [{1}] {2} | {3} | {4}{5}' -f ($i+1),$mark,$name,$kind,$date,$estimate)
            $mouseRows.Add(($i+1),$row)
            Write-Host $row
            Write-Host ('         '+$candidate.sourcePath)
        }
        if(!$Candidates.Count){Write-Host 'Список пуст после поиска. Enter / Q — повторить поиск; A — добавить папку вручную.'}
        if($pages -gt 1){Write-Host 'N — следующая страница; P — предыдущая.'}
        $names=(@($Candidates|Where-Object{$_.selected}|ForEach-Object{[IO.Path]::GetFileName($_.sourcePath.TrimEnd('\','/'))}) -join ', ')
        if($names.Length -gt 110){$names=$names.Substring(0,107)+'…'}
        $saveLine='S'+$(if($checked -gt 0){' / Enter'}else{''})+' — Подключить выбранные ('+$checked+'): '+$(if($names){$names}else{'ничего не отмечено'})
        $viewLine='V — '+$(if($selectedOnly){'Показать все папки'}else{'Показать только выбранные папки ('+$checked+')'})
        Write-Host $saveLine;Write-Host $viewLine
        $mouseRows.Add(-83,$saveLine);$mouseRows.Add(-86,$viewLine)
        Write-Host ($(if($checked -gt 0){'Q'}else{'Enter/Q'})+' — поиск; F — поиск внутри папки; A — точные пути; 0 — отмена.')
        Write-Host 'Номера: 1,3 или 1.3 или 1 3. Отметьте папки, затем Enter — подключить выбранные.'
        if($mouse){Write-Host 'Мышь: строки с [ ] меняют отметки; пункты S и V внизу также нажимаются.'}
        $choice=(Read-RemoteSyncConsoleChoice $mouseRows $mouse).Trim()
        if(!$choice){$choice=if($checked -gt 0){'S'}else{'Q'}}
        if($choice -eq '0'){return [pscustomobject]@{cancelled=$true;selection=$null}}
        if($choice -match '^[vVмМ]$'){$selectedOnly=!$selectedOnly;$page=0;continue}
        if($choice -match '^[nNтТ]$'){$page=[Math]::Min($pages-1,$page+1);continue}
        if($choice -match '^[pPзЗ]$'){$page=[Math]::Max(0,$page-1);continue}
        if($choice -match '^[qQйЙ]$'){$searchPending=$true;continue}
        if($choice -match '^[fFаА]$'){
            $text=Read-Host 'В какой папке искать репозитории (включая вложенные)? Enter — назад'
            if($text){try{
                $roots=@(ConvertFrom-RemoteSyncProjectPaths $text)
                Write-Host 'Ищем репозитории внутри указанной папки…'
                $found=Find-RemoteSyncQuickRepositories -RootPaths $roots -DataDir $DataDir -HostId $HostId -MaxSeconds 30 -MaxDepth 8
                $Candidates=@(Merge-RemoteSyncProjectCandidates -Existing $Candidates -Found $found.candidates);$page=0
                Write-Host (Format-RemoteSyncQuickSearchStatus $found)
            }catch{Write-Host $_.Exception.Message}};continue
        }
        if($choice -match '^[sSыЫ]$'){
            try{
                $result=Save-RemoteSyncSelection -DataDir $DataDir -HostId $HostId -Candidates $Candidates
                $chosen=@($Candidates|Where-Object{$_.selected})
                Write-Host ('Выбор сохранён. Подключать проектов: '+$chosen.Count+'.')
                foreach($project in $chosen){Write-Host ('  '+$project.sourcePath)}
                if($chosen.Count){Write-Host 'Далее — подготовка серверного проекта и отдельной копии Windows, проверка синхронизации и отдельное разрешение команд. Исходные папки не изменяются.'}
                return [pscustomobject]@{cancelled=$false;selection=$result}
            }catch{Write-Host $_.Exception.Message;continue}
        }
        if($choice -match '^[aAфФ]$'){
            Write-Host 'Вставляйте пути по одному. Пустая строка завершает список.'
            $lines=New-Object 'Collections.Generic.List[string]'
            do{$line=Read-Host 'Папка';if($line){$lines.Add($line)}}while($line)
            try{
                $new=@(Get-RemoteSyncProjectCandidates -Paths (ConvertFrom-RemoteSyncProjectPaths -Text ($lines -join "`n")) -DataDir $DataDir -HostId $HostId)
                $Candidates=@(Merge-RemoteSyncProjectCandidates -Existing $Candidates -Found $new);$page=0
            }catch{Write-Host $_.Exception.Message};continue
        }
        $numbers=@($choice -split '[,.;\s]+'|Where-Object{$_});$valid=($numbers.Count -gt 0);$indices=New-Object 'Collections.Generic.List[int]'
        foreach($number in $numbers){$value=0;if(![int]::TryParse($number,[ref]$value) -or $value -lt 1 -or $value -gt $Candidates.Count){$valid=$false}else{$indices.Add($value)}}
        if(!$valid){Write-Host 'Введите номера из списка.';continue}
        foreach($number in ($indices|Select-Object -Unique)){$Candidates[$number-1].selected=-not $Candidates[$number-1].selected}
    }
}
function Show-RemoteSyncProjectSelection {
    param([string]$DataDir,[string]$HostId,[switch]$Console,[switch]$Window)
    if($Console -and $Window){throw 'Choose console or window, not both'}
    $saved=Get-RemoteSyncSelection -DataDir $DataDir -HostId $HostId
    $candidates=@()
    foreach($entry in $saved.projects){
        # Previously discovered unchecked paths are not bindings. Do not rescan
        # the entire old discovery list just to add one more folder later.
        if(!$entry.selected -and !(Test-Path -LiteralPath (Join-Path (Get-SyncStatePath $DataDir $entry.projectId $HostId) 'project.json'))){continue}
        try{$candidates+=@(Get-RemoteSyncProjectCandidate -SourcePath $entry.sourcePath -DataDir $DataDir -HostId $HostId -MaxSeconds 3 -MetadataMaxSeconds 1 -MetadataMaxFiles 5000 -MetadataMaxDirectories 500)}
        catch{
            $candidates+=,[pscustomobject]@{sourcePath=$entry.sourcePath;projectId=$entry.projectId;scopeMode=$entry.scopeMode;kind='folder';selected=[bool]$entry.selected;inventory=[pscustomobject]@{lastSourceWriteUtc=$null;bytes=0;fileCount=0;complete=$false;reasons=@('Папка недоступна');largeFileCount=0;excludedCount=0}}
            Write-Host ('Папка временно недоступна: '+$entry.sourcePath+'. Верните доступ или снимите галочку.')
        }
    }
    $canShow=($Window -and -not $Console -and [Environment]::UserInteractive -and [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')
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
