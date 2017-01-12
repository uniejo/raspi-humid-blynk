#!/usr/bin/env node

//
// Main purpose:
// Control relays for heater and cooler, while monitoring temperature and humidity.
// To heat an object to dry it out.
//
// Second purpose:
// Measuring the total degree-days for several items in storage, and give out warnings
// for each item as it is about to reach the wanted degree-days.
//
// Inputs:  two buttons, DHT11 temperature/humidity sensor
// Outputs: four relay outputs (only two used)
// Control: Blynk app
//
// Environment variables:
// I usually need to set NODE_PATH=/usr/local/lib/node_modules before running this script.
//

var BLYNK_AUTH    = process.argv[2];
var MAIL_DEST     = process.argv[3];
var BLYNK_ADDR    = "blynk-cloud.com"; // or f.ex. "127.0.0.1";

var LANG          = 'en';

var SAVE_FILE     = "humid_blynk.json";
var TEMP_UNIT     = '⁰C';
var HUMID_UNIT    = '%';
var DGD_UNIT      = { da:'graddage', en: "degree days" }[LANG];
var READ_INTERVAL = 5000;       // 5 seconds (suggested interval)

var DHT_TYPE      = 11;         // 11=DHT11, 22=DHT22/AM2302
var DHT_PIN       = 4;          // I2C pin 4 where DHT11/DHT22 is attached

var BLYNK_AUTH_length = BLYNK_AUTH == null ? 0 : BLYNK_AUTH.length;

if ( BLYNK_AUTH_length != 32 ) {
    log(
        "\n"+
        "Syntax: "+process.argv[1]+" <blynk-token> <email-address>\n"+
        "\n"+
        "<blynk-token>   : Blynk token (expected length 32, got "+BLYNK_AUTH_length+"): "+BLYNK_AUTH+"\n"+
        "<email-address> : Email address for notifications\n"+
        "\n"
    );
    process.exit();
}


//
// Saved to SAVE_FILE
//
var req_humid       = 10;
var req_temp_days   = 40;
var max_temp        = 30;
var temp_days_list  = [];


// Note: node-dht-sensor 0.0.11 is problematic so use
// sudo npm install -g node-dht-sensor@0.0.8 --unsafe-perm=true

var fs        = require("fs");
var Blynk     = require("blynk-library");
var Gpio      = require("onoff").Gpio;
var sensorLib = require('node-dht-sensor');

// Blynk by default connects to blynk-cloud.com:8441 (ssl)
// port 8443 (ssl),  port 8442 (not encrypted) or port 8441 (local)
//var blynk = new Blynk.Blynk(BLYNK_AUTH);
var blynk = new Blynk.Blynk(BLYNK_AUTH, options={addr: BLYNK_ADDR});

var readout;
var readout_time;
var stage_changed_time = hrtime_secs();

//
// INPUTS (physical)
//
var i_start_heat    = new Gpio(23, 'in', 'both');  // Start/Stop heat button (falling/both)
var i_push_day      = new Gpio(17, 'in', 'both');  // Start days  button
// (Edge: rising/falling/both)

//
// OUTPUTS (physical)
//
var o_heat          = new Gpio(18, 'out');            // Heater, relay output 1
var o_fan           = new Gpio(24, 'out');            // Fan,    relay output 2
var o_relay_3       = new Gpio(27, 'out');            // ---,    relay output 3
var o_relay_4       = new Gpio(22, 'out');            // ---,    relay output 4


//
// INPUT/OUTPUT connected to Blynk app
//
//Inputs: buttons
var v_start_heat    = new blynk.VirtualPin(0);        // Start (& stop) heater button
var v_push_day      = new blynk.VirtualPin(1);        // Start days button (push)
var v_pop_day       = new blynk.VirtualPin(2);        // Remove day button (pop, oldest)
var v_shift_day     = new blynk.VirtualPin(3);        // Remove day button (shift, newest)

//Inputs: sliders
var v_req_humid     = new blynk.VirtualPin(5);        // Requested humidity
var v_req_temp_days = new blynk.VirtualPin(6);        // Requested temp days
var v_max_temp      = new blynk.VirtualPin(7);        // Max temp (from blynk UI)

//Outputs:
var v_humid         = new blynk.VirtualPin(10);        // Current humidity
var v_temp          = new blynk.VirtualPin(11);        // Current temperature
var v_dgd_summary   = new blynk.VirtualPin(12);        // Total degree days (summary display)(console)
//var v_dgd_table     = new blynk.VirtualPin(13);        // Total degree days (table)

var v_stage         = "ready";
var v_ready         = new blynk.VirtualPin(20);
var v_heating       = new blynk.VirtualPin(21);
var v_pause         = new blynk.VirtualPin(22);
var v_cool          = new blynk.VirtualPin(23);
var v_done          = new blynk.VirtualPin(24);
var v_stage_time    = "-";

var v_console       = new blynk.VirtualPin(30);

var t_sensor;
var t_run;

//v_dgd_table.addRow(1,


function log(message) {
    // Workaround for join
    var txt = message;
    for(var i = 0; i<arguments.length; i++) {
        if ( i > 0 ) {
            txt += arguments[i];
        }
    }

    console.log(txt);
}

function save_data() {
    var save_data = { };

    if ( req_temp_days  ) save_data.req_temp_days  = req_temp_days;
    if ( req_humid      ) save_data.req_humid      = req_humid;
    if ( temp_days_list ) save_data.temp_days_list = temp_days_list;
    if ( max_temp       ) save_data.max_temp       = max_temp;

    fs.writeFileSync(SAVE_FILE, JSON.stringify(save_data) );
}

function cleanup() {
    if ( t_sensor ) clearInterval( t_sensor );
    if ( t_run    ) clearInterval( t_run );
    i_start_heat.unexport();
    i_push_day.unexport();
    o_heat.unexport();
    o_fan.unexport();
    o_relay_3.unexport();
    o_relay_4.unexport();
    blynk.disconnect();
    save_data();
}
process.on('SIGINT', cleanup);
process.on('SIGABRT', cleanup);

function hrtime_secs () {
    var t = process.hrtime();
    return t[0] + (t[1] / 1000000000);
}

function update_degree_days_list(readout) {
    var old_readout_time = readout_time;
    readout_time = hrtime_secs();
    if ( old_readout_time == null ) return;
    if ( temp_days_list.length == 0 ) return;

    var delta_secs = readout_time - old_readout_time;
    var delta_temp_days = readout.temperature.toFixed(5) * delta_secs / 86400;

    var notices = [];

    for(var i = 0; i<temp_days_list.length; i++) {
       var timer = temp_days_list[i];
       var old_temp_days = timer.temp_days;
       timer.temp_days += delta_temp_days;

       timer.day_avg = timer.temp_days * 86400 * 1000 / (Date.now() - timer.started);
       timer.etc = timer.started + ( timer.req_temp_days / timer.day_avg * 86400 * 1000 )

       //log("Timer "+i+" Next warning level: "+timer.warnings[0].temp_days);

       while ( timer.warnings.length > 0 && timer.warnings[0].temp_days <= timer.temp_days ) {
           var warning = timer.warnings[0];
           // Send out warning
           log("Warning level "+warning.temp_days+" (temp days) "+(warning.text==null ? "" : "("+warning.text+") ")+"reached");
           var etc_dt   = (new Date( timer.etc     )).toLocaleString();
           var start_dt = (new Date( timer.started )).toLocaleString();

           var notice = {
             en:        "Has passed "+warning.temp_days+" "+DGD_UNIT+
                        " ("+old_temp_days+") out of " + timer.req_temp_days + "\n"+
                        "started  "+start_dt+"\n"+
                        "ETC:     "+etc_dt+"\n",
             da:        "Har passeret "+warning.temp_days+" "+DGD_UNIT+
                        " ("+old_temp_days+") ud af " + timer.req_temp_days + "\n"+
                        "som blev startet "+start_dt+"\n"+
                        "forventet ETC:   "+etc_dt+"\n",
           }[LANG];

           notices.push(notice);
           timer.warnings.pop();
           // Click relay to indicate change
           o_relay_3.writeSync( 1 );
           setTimeout(function(){ o_relay_3.writeSync( 0 ); },  500);
           setTimeout(function(){ o_relay_3.writeSync( 1 ); }, 1500);
           setTimeout(function(){ o_relay_3.writeSync( 0 ); }, 2000);
       }

       if ( timer.warnings == null || timer.warnings.length == 0 ) {
           // Erase this timer from temp_days_list (and make sure that next loop works out
           temp_days_list.splice(i,1);
           i--;
       }
    }

    if ( temp_days_list == null || temp_days_list.length == 0 ) {
        v_pop_day.write(   0 );
        v_shift_day.write( 0 );
    }

    if ( notices.length > 0 ) {
        log("Notices to send: "+ notices.length);
        send_notification( notices );
    }
}

function show_degree_days() {
//
    var summary = get_degree_days();
    v_dgd_summary.write( pad_lines( summary ) );
}

function pad_lines( text ) {
    var lines_remain = 8;
    var lines = text.split("\n");
    for(var i = 0; i<lines.length; i++) {
        lines_remain = lines_remain - ( 0 + (lines[i].length / 46) >> 0 );
    }
    for(; lines_remain>0; lines_remain--) {
        text += "\n";
    }
    return text;
}

function send_notification(notices) {
    var summary = notices.join("\n") +"\n\n" + get_degree_days();
    log("Sending report to "+MAIL_DEST);
    blynk.email( MAIL_DEST, 'Heater report', summary);
}

function get_degree_days() {
    if ( temp_days_list.length == 0 ) {
        return { en: "No active timers.\n", da: "Ingen aktive timers.\n" }[LANG];
    }

    var summary_notice  = null;
    var summary_list    = [];

    for(var i = 0; i<temp_days_list.length; i++) {
       var timer = temp_days_list[i];
       if ( timer.temp_days == 0 ) continue;

       summary_list.push( timer.temp_days.toFixed(2) );

       var etc_dt = (new Date( timer.etc )).toLocaleString();

//     log("#"+ i +"  total = "+timer.temp_days.toFixed(4) + " of " + timer.req_temp_days.toFixed(4) +  "  ETC: "+etc_dt);

       if ( summary_notice == null ) summary_notice = "ETC: "+etc_dt;
    }

    var summary = summary_list.length + " : " +
        summary_list.join(", ") +
        ( summary_notice == null ? summary_list.length+": " : "\n"+summary_notice );

    return summary;
}

function top_degree_day() {
    if ( temp_days_list == null    ) return "";
    var top;
    for(var i = 0; i<temp_days_list.length; i++) {
       var timer = temp_days_list[i];
       if ( top != null && top.etc != null && timer.etc != null && top.etc>timer.etc ) continue;
       top = timer;
    }
    if ( top == null ) return "";
    var etc_dt   = (new Date( top.etc     )).toLocaleString();
    var start_dt = (new Date( top.started )).toLocaleString();
    var toptext =
        "   "+top.temp_days.toFixed(4) + " of " + top.req_temp_days.toFixed(0)+
        "  ETC: "+etc_dt+"   Started: "+start_dt;

    return toptext;
}

var sensor = {
    initialize: function () {
        return sensorLib.initialize(DHT_TYPE, DHT_PIN); // Type: 11=DHT11, 22=DHT22/AM2302; Pin: f.ex. pin 4
    },
    read: function () {
 //     log("Start readout");
        readout = sensorLib.read();
        if ( (readout.humidity.toFixed(1) == 0.0) && (readout.temperature.toFixed(1) == 0.0) ) return;

        log(
            "Temperature: " + readout.temperature.toFixed(2) + " " + TEMP_UNIT + ",  " +
            "Humidity: "    + readout.humidity.toFixed(2)    + " " + HUMID_UNIT +
            top_degree_day()
        );

        v_temp.write(  readout.temperature.toFixed(2) + TEMP_UNIT);
        v_humid.write( readout.humidity.toFixed(2)    + HUMID_UNIT);

        run_stage();
        update_degree_days_list(readout);
        show_degree_days();

    },
};

fs.readFile(SAVE_FILE, function(err, buf) {
    if (err ) {
        if ( err != ENOENT ) console.warn("Reading save file failed: " + err);
        return;
    }
    log("Read save file: " + buf);

    var save_data = JSON.parse( buf );

    if ( save_data.max_temp_days  ) max_temp_days  = save_data.max_temp_days;
    if ( save_data.req_humid      ) req_humid      = save_data.req_humid;
    if ( save_data.temp_days_list ) temp_days_list = save_data.temp_days_list;
    if ( save_data.max_temp       ) max_temp       = save_data.max_temp;

    log("Read save total temp: " + buf);

    v_pop_day.write(   temp_days_list.length == 0 ? 0 : 1);
    v_shift_day.write( temp_days_list.length == 0 ? 0 : 1);
});

if ( sensor.initialize() ) {
    t_sensor = setInterval(sensor.read, READ_INTERVAL);
} else {
    console.warn("Failed to initialize sensor");
}


function set_stage (stage) {
    if ( v_stage == stage ) return;
    log("Change stage from ", v_stage, " to ", stage);
    stage_changed_time = hrtime_secs();
    v_stage = stage;

    // Starting the heat creates a surge that may look like a keypress. So ignore keypresses for a short while.
    if ( stage == 'heating' ) {
        i_start_heat_t = Date.now();
        i_push_day_t   = Date.now();
    }

    v_ready.write(   v_stage == 'ready'   ? 255 : 0 );
    v_heating.write( v_stage == 'heating' ? 255 : 0 );
    v_pause.write(   v_stage == 'pause'   ? 255 : 0 );
    v_cool.write(    v_stage == 'cool'    ? 255 : 0 );
    v_done.write(    v_stage == 'done'    ? 255 : 0 );

    o_heat.writeSync( v_stage == 'heating' ? 1 : 0 );
    o_fan.writeSync(  v_stage == 'cool'    ? 1 : 0 );

    if ( stage == 'done' ) {
        setTimeout(function(){ set_stage('ready'); }, 2000);
    }
}

function is_idle() {
    return ( (v_stage == 'ready' ) || (v_stage == 'done') );
}

function run_stage() {
    if ( is_idle() ) return;
    if ( ! readout_time ) return;
    // Right after changing previous stage, could cause a surge in the reading.
//   if ( i_start_heat_t != null && ( Date.now() - i_start_heat_t ) < 100 ) return;
    var stage_dt = hrtime_secs()-stage_changed_time;
    if ( readout.humidity <= req_humid ) {
//      log("Requested humidity " + req_humid + " reached: "+readout.humidity+" for "+stage_dt.toFixed(1)+" sec");
        if ( v_stage == 'pause' && stage_dt > 60 ) {
            set_stage('done');
        }
        else if ( v_stage == 'heating' ) {
            set_stage('pause');
        }
    }
    else if ( readout.temperature < max_temp ) {
        set_stage('heating');
    }
    else {
        set_stage('pause');
    }
    // TODO:
}


blynk.on('connect', function() {
    log("Blynk ready.");
    blynk.syncAll();
});

blynk.on('disconnect', function() {
    log("Blynk disconnected.");
});

blynk.on('error', function() {
    log("Blynk error.");
});


var i_start_heat_t = null;
function start_heat_button(value, origin) {

//  log("start_heat_button "+value);

    if ( value == 1 || i_start_heat_t == null ) {
        i_start_heat_t = Date.now();
//      log("Button pressed: "+origin);
        return;
    }

    var dt = Date.now() - i_start_heat_t;
    if ( dt < 15 ) {
        log("Start heat button press_time="+dt+" - short time = ignored" );
    } else if ( dt < 1500 ) {
        log("Start heat button press_time="+dt+" - Start heating" );
        set_stage( "heating" );
    } else {
        log("Start heat button press_time="+dt+" - Stop heating" );
        set_stage( "ready" );
    }
    i_start_heat_t = null;
}

i_start_heat.watch(function(err, value) {
    start_heat_button(1-value, "Button 1")
});
v_start_heat.on('write', function(param) {
    start_heat_button(param[0], "Start button (blynk app)");
});

function push_day () {
    if ( req_temp_days == null ) req_temp_days = 40;

    var timer = {
        started:       Date.now(),
        etc:           Date.now(),
        temp_days:     0.0,
        req_temp_days: req_temp_days,
        warnings: [
            {
                temp_days: req_temp_days - 1.0,
                text:      {en: "One dgd remaining",    da: "En graddag tilbage"               }[LANG],
            },
            {
                temp_days: req_temp_days - 0.5,
                text:      {en: "Half a dgd remaining", da: "En halv graddag tilbage"          }[LANG],
            },
            {
                temp_days: req_temp_days + 0.0,
                text:      {en: "Done",                 da: "Faerdig"                           }[LANG],
            },
            {
                temp_days: req_temp_days + 0.5,
                text:      {en: "Done half dgd ago",    da: "Faerdig for en halv graddag siden" }[LANG],
            }
        ],
    };

    // For short time, remove what has already passed
    while ( timer.warnings.length > 0 && timer.warnings[0].temp_days < 0.0 ) {
        timer.warnings.pop();
    }

    log("Push new day timer ("+req_temp_days+" "+DGD_UNIT+")");
    temp_days_list.push( timer );
    show_degree_days();
    v_pop_day.write(   temp_days_list.length == 0 ? 0 : 1);
    v_shift_day.write( temp_days_list.length == 0 ? 0 : 1);

    // Click feedback
    o_relay_3.writeSync( 1 );
    setTimeout(function(){ o_relay_3.writeSync( 0 ); },  500);
}

function pop_day () {
    temp_days_list.pop();
    log("Pop day timer ("+req_temp_days+" "+DGD_UNIT+")");
    show_degree_days();
    v_pop_day.write(   temp_days_list.length == 0 ? 0 : 1);
    v_shift_day.write( temp_days_list.length == 0 ? 0 : 1);

    // Click feedback
    o_relay_3.writeSync( 1 );
    setTimeout(function(){ o_relay_3.writeSync( 0 ); },  500);
}

function shift_day () {
    temp_days_list.shift();
    log("Shift day timer ("+req_temp_days+" "+DGD_UNIT+")");
    show_degree_days();
    v_pop_day.write(   temp_days_list.length == 0 ? 0 : 1);
    v_shift_day.write( temp_days_list.length == 0 ? 0 : 1);

    // Click feedback
    o_relay_3.writeSync( 1 );
    setTimeout(function(){ o_relay_3.writeSync( 0 ); },  500);
}

var i_push_day_t = null;
i_push_day.watch(function(err, value) {
    if ( value == 0 || i_push_day_t == null ) { i_push_day_t = Date.now(); return; }
    var dt = Date.now() - i_push_day_t;
    log("Button 2 (start counter) press_time="+dt);
    if ( dt < 15 ) {
        log("Button 2 press_time="+dt+" - Short time = ignored");
    } else if ( dt < 1000 ) {
        push_day();
    } else {
        pop_day();
    }
    i_push_day_t = null;
});
v_push_day.on('write', function(param) {
//  log(param[0]==1 ? "Start" : "Stop", " (", param[0], ")");
    if ( param[0]==1 ) push_day();
});
v_pop_day.on('write', function(param) {
    if ( param[0]==1 ) pop_day();
});
v_shift_day.on('write', function(param) {
    if ( param[0]==1 ) shift_day();
});


v_req_humid.on('write', function(param) {
    log("Requested humidity : ", param[0], " ", HUMID_UNIT);
    if ( param[0] == null ) return;
    req_humid = param[0];
});

v_req_temp_days.on('write', function(param) {
    log("Requested temp_days : ", param[0], " ", "temp/days");
    if ( param[0] == null ) return;
    req_temp_days = param[0];
});

v_max_temp.on('write', function(param) {
    log("Requested max temp : ", param[0], " ", TEMP_UNIT);
    if ( param[0] == null ) return;
    max_temp = param[0];
});

set_stage("done");
t_run = setInterval(run_stage, 1000);
blynk.notify("Ready...");
