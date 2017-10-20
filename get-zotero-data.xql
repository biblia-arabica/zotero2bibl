xquery version "3.1";
(:~
 : XQuery Zotero integration
 : Queries Zotero API : https://api.zotero.org
 : Checks for updates since last modified version using Zotero Last-Modified-Version header
 : Converts Zotero records to Syriaca.org TEI using zotero2tei.xqm
 : Adds new records to directory.
 :
 : To be done: 
 :      Submit to Perseids
:)

import module namespace http="http://expath.org/ns/http-client";
import module namespace zotero2tei="http://syriaca.org/zotero2tei" at "zotero2tei.xqm";
declare namespace tei="http://www.tei-c.org/ns/1.0";
declare namespace output = "http://www.w3.org/2010/xslt-xquery-serialization";

declare variable $zotero-api := 'https://api.zotero.org';

(: Access zotero-api configuration file :) 
declare variable $zotero-config := doc('zotero-config.xml');
(: Zotero group id :)
declare variable $groupid := $zotero-config//groupid/text();
(: Zotero last modified version, to check for updates. :)
declare variable $last-modified-version := $zotero-config//last-modified-version/text();
(: Directory bibl data is stored in :)
declare variable $data-dir := $zotero-config//data-dir/text();
(: Local URI pattern for bibl records :)
declare variable $base-uri := $zotero-config//base-uri/text();
(: Format defaults to tei :)
declare variable $format := if($zotero-config//format/text() != '') then $zotero-config//format/text() else 'tei';

(:~
 : Convert records to Syriaca.org complient TEI records, using zotero2tei.xqm
 : Save records to the database. 
 : @param $record 
 : @param $index-number
:)
declare function local:process-items($record as item()?, $index-number as xs:integer, $format as xs:string?){
    let $id := local:make-local-uri($index-number)
    let $file-name := concat($index-number,'.xml')
    let $new-record := zotero2tei:build-new-record($record, $id, $format)
    return 
        try {
            <response status="200">
                    <message>{xmldb:store($data-dir, xmldb:encode-uri($file-name), $new-record)}</message>
                </response>
        } catch *{
            <response status="fail">
                <message>Failed to add resource {$id}: {concat($err:code, ": ", $err:description)}</message>
            </response>
        } 
};

(:~
 : Get highest existing local id in the eXist database. Increment new record ids
 : @param $path to existing bibliographic data
 : @param $base-uri base uri defined in repo.xml, establishing pattern for bibl ids. example: http://syriaca.org/bibl 
:)
declare function local:make-local-uri($index-number as xs:integer) {
    let $all-bibl-ids := 
            for $uri in collection($data-dir)/tei:TEI/tei:text/tei:body/tei:biblStruct/descendant::tei:idno[starts-with(.,$base-uri)]
            return number(replace(replace($uri,$base-uri,''),'/tei',''))
    let $max := max($all-bibl-ids)          
    return
        if($max) then concat($base-uri,'/', ($max + $index-number))
        else concat($base-uri,'/',$index-number)
};

(:~
 : Update stored last modified version (from Zotero API) in zotero-config.xml
:)
declare function local:update-version($version as xs:string?) {
    try {
            <response status="200">
                    <message>{for $v in $zotero-config//last-modified-version return update value $v with $version}</message>
                </response>
        } catch *{
            <response status="fail">
                <message>Failed to update last-modified-version: {concat($err:code, ": ", $err:description)}</message>
            </response>
        } 
};

(:~
 : Page through Zotero results
 : @param $groupid
 : @param $last-modified-version
 : @param $total
 : @param $start
 : @param $perpage
:)
declare function local:get-next($total as xs:integer?, $start as xs:integer?, $perpage as xs:integer?, $format as xs:string?){
let $items := local:get-zotero-data($total, $start, $perpage,$format)
let $headers := $items[1]
let $results := 
    if($format = 'json') then 
        parse-json(util:binary-to-string($items[2])) 
    else $items[2]
let $next := if(($start + $perpage) lt $total) then $start + $perpage else ()
return 
    if($headers/@status = '200') then
        (
        if($format = 'json') then
            for $rec at $p in $results?*
            let $rec-num := $start + $p
            return local:process-items($rec, $rec-num, $format)
        else 
            for $rec at $p in $results//tei:biblStruct
            let $rec-num := $start + $p
            return local:process-items($rec, $rec-num, $format),
        if($next) then 
            local:get-next($total, $next, $perpage,$format)
        else ())
    else if($headers/@name="Backoff") then
        (<message status="{$headers/@status}">{string($headers/@message)}</message>,
            let $wait := util:wait(xs:integer($headers[@name="Backoff"][@value]))
            return local:get-next($total, $next, $perpage,$format)
        )
    else if($headers/@name="Retry-After") then   
        (<message status="{$headers/@status}">{string($headers/@message)}</message>,
            let $wait := util:wait(xs:integer($headers[@name="Retry-After"][@value]))
            return local:get-next($total, $next, $perpage,$format)
        )
    else  <message status="{$headers/@status}">{string($headers/@message)}</message>          
};

(:~
 : Get Zotero data
 : Check for updates since last modified version (stored in $zotero-config)
 : @param $groupid Zotero group id
 : @param $last-modified-version
:)
declare function local:get-zotero-data($total as xs:integer?, $start as xs:integer?, $perpage as xs:integer?, $format as xs:string?){
let $start := if(not(empty($start))) then concat('&amp;start=',$start) else ()
let $url := concat($zotero-api,'/groups/',$groupid,'/items?format=',$format,$start)
return 
    if(request:get-parameter('action', '') = 'initiate') then 
        http:send-request(<http:request http-version="1.1" href="{xs:anyURI($url)}" method="get">
                         <http:header name="Connection" value="close"/>
                       </http:request>)
    else                    
        http:send-request(<http:request http-version="1.1" href="{xs:anyURI($url)}" method="get">
                         <http:header name="Connection" value="close"/>
                         <http:header name="If-Modified-Since-Version" value="{$last-modified-version}"/>
                       </http:request>)                       
};

(:~
 : Get and process Zotero data. 
:)
declare function local:get-zotero(){
    let $items := local:get-zotero-data((), (), (),$format)
    let $items-info := local:get-zotero-data((), (), (),$format)[1]
    let $total := $items-info/http:header[@name='total-results']/@value
    let $version := $items-info/http:header[@name='last-modified-version']/@value
    let $perpage := 24
    let $pages := xs:integer($total div $perpage)
    let $start := 0
    return 
        if($items-info/@status = '200') then
          (local:get-next($total, $start, $perpage,$format),
           local:update-version($version))
        else <message status="{$items-info/@status}">{string($items-info/@message)}</message>   
};

(: Helper function to recursively create a collection hierarchy. :)
declare function local:mkcol-recursive($collection, $components) {
    if (exists($components)) then
        let $newColl := concat($collection, "/", $components[1])
        return (
            xmldb:create-collection($collection, $components[1]),
            local:mkcol-recursive($newColl, subsequence($components, 2))
        )
    else ()
};

(: Helper function to recursively create a collection hierarchy. :)
declare function local:mkcol($collection, $path) {
    local:mkcol-recursive($collection, tokenize($path, "/"))
};

(:~
 : Check action parameter, if empty, return contents of config.xml
 : If $action is not empty, check for specified collection, create if it does not exist. 
 : Run Zotero request. 
:)
if(request:get-parameter('action', '') != '') then
    if(xmldb:collection-available($data-dir)) then
        local:get-zotero()
    else (local:mkcol("/db/apps", replace($data-dir,'/db/apps','')),local:get-zotero())
else 
    <div>
        <p><label>Group ID : </label> {$groupid}</p>
        <p><label>Last Modified Version (Zotero): </label> {$last-modified-version}</p>
        <p><label>Data Directory : </label> {$data-dir}</p>    
    </div>