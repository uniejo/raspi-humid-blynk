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

var BLYNK_AUTH   = process.argv[2];
var MAIL_DEST    = process.argv[3];

var SAVE_FILE    = "humid_blynk.json";
var MAX_TEMP     = 30;

var BLYNK_AUTH_length = BLYNK_AUTH == null ? 0 : BLYNK_AUTH.length;
if ( BLYNK_AUTH_length != 32 ) {
    console.log("Please supply Blynk auth token as first argument (length "+BLYNK_AUTH_length+"; should be 32): "+BLYNK_AUTH);
    process.exit();
}


//
// Saved to SAVE_FILE
//
var req_humid       = 10;
var req_temp_days   = 40;
var temp_days_list  = [];


// Note: node-dht-sensor 0.0.11 is problematic so use
// sudo npm install -g node-dht-sensor@0.0.8 --unsafe-perm=true

var fs        = require("fs");
var Blynk     = require("blynk-library");
var Gpio      = require("onoff").Gpio;
var sensorLib = require('node-dht-sensor');

var blynk = new Blynk.Blynk(BLYNK_AUTH);

var readout;
var readout_time;

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
var v_start_heat    = new blynk.VirtualPin(0);        // Start (& stop) heater button
var v_push_day      = new blynk.VirtualPin(1);        // Start days button (push)
var v_pop_day       = new blynk.VirtualPin(2);        // Remove day button (pop, oldest)
var v_shift_day     = new blynk.VirtualPin(3);        // Remove day button (shift, newest)

var v_req_humid     = new blynk.VirtualPin(5);        // Requested humidity
var v_req_temp_days = new blynk.VirtualPin(6);        // Requested temp days

var v_humid         = new blynk.VirtualPin(10);        // Current humidity
var v_temp          = new blynk.VirtualPin(11);        // Requested humidity
var v_temp_days     = new blynk.VirtualPin(12);        // Total temp days (summary display)

var v_stage         = "-";
var v_ready         = new blynk.VirtualPin(20);
var v_heating       = new blynk.VirtualPin(21);
var v_pause         = new blynk.VirtualPin(22);
var v_cool          = new blynk.VirtualPin(23);
var v_done          = new blynk.VirtualPin(24);


var t_sensor;
var t_run;

function save_data() {
    var save_data = { };

    if ( req_temp_days  ) save_data.req_temp_days  = req_temp_days;
    if ( req_humid      ) save_data.req_humid      = req_humid;
    if ( temp_days_list ) save_data.temp_days_list = temp_days_list;

    fs.writeFileSync(SAVE_FILE, JSON.stringify(save_data) );
}

function cleanup() {
    if ( t_sensor ) clearInterval( t_sensor );
    if ( t_run    ) clearInterval( t_run );
    i_start_heat.unexport();
    i_push_day.unexport();
    o_heat.unexport();
    o_fan.unexport();
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

       //console.log("Timer "+i+" Next warning level: "+timer.warnings[0].temp_days);

       while ( timer.warnings.length > 0 && timer.warnings[0].temp_days <= timer.temp_days ) {
           var warning = timer.warnings[0];
           // Send out warning
           console.log("Warning level "+warning.temp_days+" (temp days) reached");
           var etc_dt   = (new Date( timer.etc     )).toLocaleString();
           var start_dt = (new Date( timer.started )).toLocaleString();
           var notice = "Har passeret "+warning.temp_days+" graddage ("+old_temp_days+")\n"+
                        "som blev startet "+start_dt+"\n"+
                        "forventet ETC:   "+etc_dt+"\n";
           notices.push(notice);
           timer.warnings.pop();
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
        console.log("Notices to send: "+ notices.length);
        send_notification( notices );
    }
}

function show_degree_days() {
    var summary = get_degree_days();
    v_temp_days.write(summary);
}

function send_notification(notices) {
    var summary = notices.join("\n") +"\n\n" + get_degree_days();
    console.log("Sending report to "+MAIL_DEST);
    Blynk.email( MAIL_DEST, 'Heater report', summary);
}

function get_degree_days() {
    if ( temp_days_list.length == 0 ) {
        v_temp_days.write("Ingen aktiv.");
        return;
    }

    var summary_notice  = null;
    var summary_list    = [];

    for(var i = 0; i<temp_days_list.length; i++) {
       var timer = temp_days_list[i];
       if ( timer.temp_days == 0 ) continue;

       summary_list.push( timer.temp_days.toFixed(2) );

       var etc_dt = (new Date( timer.etc )).toLocaleString();
       console.log("delta_time #"+ i +"  total = "+timer.temp_days.toFixed(4) + "  ETC: "+etc_dt);
       if ( summary_notice == null ) summary_notice = "ETC: "+etc_dt;
    }

    var summary = summary_list.length + " : " +
        summary_list.join(", ") +
        ( summary_notice == null ? summary_list.length+": " : "\n"+summary_notice );

    return summary;
}

var sensor = {
    initialize: function () {
        return sensorLib.initialize(11, 4); // 11=DHT11, 22=DHT22/AM2302; pin 4
    },
    read: function () {
//      console.log("Start readout");
        readout = sensorLib.read();
        if ( (readout.humidity.toFixed(1) == 0.0) && (readout.temperature.toFixed(1) == 0.0) ) return;

        console.log("Temperature: " + readout.temperature.toFixed(2) + "C, " +
            " humidity: "+ readout.humidity.toFixed(2) + '%');

        v_temp.write( readout.temperature.toFixed(2) + 'C');
        v_humid.write(readout.humidity.toFixed(2)    + '%');

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
    console.log("Read save file: " + buf);

    var save_data = JSON.parse( buf );

    if ( save_data.max_temp_days  ) max_temp_days  = save_data.max_temp_days;
    if ( save_data.req_humid      ) req_humid      = save_data.req_humid;
    if ( save_data.temp_days_list ) temp_days_list = save_data.temp_days_list;

    console.log("Read save total temp: " + buf);

    v_pop_day.write(   temp_days_list.length == 0 ? 0 : 1);
    v_shift_day.write( temp_days_list.length == 0 ? 0 : 1);
});

if ( sensor.initialize() ) {
    t_sensor = setInterval(sensor.read, 2000);
} else {
    console.warn("Failed to initialize sensor");
}

function set_stage (stage) {
    if ( v_stage == stage ) return;
    console.log("Change stage from ", v_stage, " to ", stage);
    v_stage = stage;

    // Starting the heat creates a surge that may look like a keypress. So ignore keypresses for a short while.
    if ( stage == 'heating' ) {
        i_start_heat_t = Date.now();
        i_push_day_t = Date.now();
    }

    v_ready.write(   v_stage == 'ready'   ? 255 : 0 );
    v_heating.write( v_stage == 'heating' ? 255 : 0 );
    v_pause.write(   v_stage == 'pause'   ? 255 : 0 );
    v_cool.write(    v_stage == 'cool'    ? 255 : 0 );
    v_done.write(    v_stage == 'done'    ? 255 : 0 );

    o_heat.writeSync( v_stage == 'heating' ? 1 : 0 );
    o_fan.writeSync(  v_stage == 'cool'    ? 1 : 0 );
}

function is_idle() {
    return ( (v_stage == 'ready' ) || (v_stage == 'done') );
}

function run_stage() {
    if ( is_idle() ) return;
    if ( ! readout_time ) return;
    // Right after changing previous stage, could cause a surge in the reading.
    if ( i_start_heat_t != null && ( Date.now() - i_start_heat_t ) < 100 ) return;
    if ( readout.humidity <= req_humid ) {
        console.log("Requested humidity " + req_humid + " reached: "+readout.humidity);
        set_stage('cool');
        setTimeout(function(){ set_stage('done'); }, 5000);
    }
    else if ( readout.temperature < MAX_TEMP ) {
        set_stage('heating');
    }
    else {
        set_stage('pause');
    }
    // TODO:
}


blynk.on('connect', function() {
    console.log("Blynk ready.");
    set_stage("ready");
});

blynk.on('disconnect', function() {
    console.log("Blynk disconnected.");
});

blynk.on('error', function() {
    console.log("Blynk error.");
});


var i_start_heat_t = null;
i_start_heat.watch(function(err, value) {
    if ( value == 0 || i_start_heat_t == null ) { i_start_heat_t = Date.now(); return; }
    var dt = Date.now() - i_start_heat_t;
    console.log("Button 1 (start/stop) press_time="+dt);
    if ( dt < 15 ) {
        console.log("Button 1 (start/stop) press_time="+dt+" - Short time = ignored");
    } else if ( dt < 1000 ) {
        // set_stage( is_idle() ? "heating" : "ready" );
        set_stage( "heating" );
    } else {
        set_stage( "ready" );
    }
    i_start_heat_t = null;
});
v_start_heat.on('write', function(param) {
    console.log(param[0]==1 ? "Start" : "Stop", " (", param[0], ")");
    set_stage( param[0]==1 ? "heating" : "ready");
});

function push_day () {
    var timer = {
        started: Date.now(),
        temp_days: 0.0,
        req_temp_days: req_temp_days,
        warnings: [
            { temp_days: req_temp_days - 1    },
            { temp_days: req_temp_days - 0.5  },
            { temp_days: req_temp_days + 0.5  }
        ],
    };
    console.log("Push new day timer (graddage="+req_temp_days+")");
    temp_days_list.push( timer );
    show_degree_days();
    v_pop_day.write(   temp_days_list.length == 0 ? 0 : 1);
    v_shift_day.write( temp_days_list.length == 0 ? 0 : 1);
}

function pop_day () {
    temp_days_list.pop();
    console.log("Pop day timer (graddage="+req_temp_days+")");
    show_degree_days();
    v_pop_day.write(   temp_days_list.length == 0 ? 0 : 1);
    v_shift_day.write( temp_days_list.length == 0 ? 0 : 1);
}

function shift_day () {
    temp_days_list.shift();
    console.log("Shift day timer (graddage="+req_temp_days+")");
    show_degree_days();
    v_pop_day.write(   temp_days_list.length == 0 ? 0 : 1);
    v_shift_day.write( temp_days_list.length == 0 ? 0 : 1);
}

var i_push_day_t = null;
i_push_day.watch(function(err, value) {
    if ( value == 0 || i_push_day_t == null ) { i_push_day_t = Date.now(); return; }
    var dt = Date.now() - i_push_day_t;
    console.log("Button 2 (start counter) press_time="+dt);
    if ( dt < 15 ) {
        console.log("Button 2 press_time="+dt+" - Short time = ignored");
    } else if ( dt < 1000 ) {
        push_day();
    } else {
        pop_day();
    }
    i_push_day_t = null;
});
v_push_day.on('write', function(param) {
//  console.log(param[0]==1 ? "Start" : "Stop", " (", param[0], ")");
    if ( param[0]==1 ) push_day();
});
v_pop_day.on('write', function(param) {
    if ( param[0]==1 ) pop_day();
});
v_shift_day.on('write', function(param) {
    if ( param[0]==1 ) shift_day();
});


v_req_humid.on('write', function(param) {
    console.log("Requested humidity : ", param[0], " %");
    req_humid = param[0];
});

v_req_temp_days.on('write', function(param) {
    console.log("Requested temp_days : ", param[0], " %");
    req_temp_days = param[0];
});


set_stage("done");
v_start_heat.write( 0 );
t_run = setInterval(run_stage, 1000);

