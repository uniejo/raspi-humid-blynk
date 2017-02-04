# raspi-humid-blynk

Humidity/temperature control on Raspberry Pi.

Hardware: Raspberry Pi 3 B + relay board + proto board with two buttons and temperature/humidity sensor.
Software: Javascript (node.js) that communicates with hardware and remote app.
App (iOS or Android): Blynk - IoT for Arduino, RPi, Particle, ESP8266


Documentation
 <ul>
 <li><a href="docs/Raspberry_Pi_dryer_overview.pdf"> Overview (pdf)</a></li>
 <li><a href="docs/Raspberry_Pi_dryer_hardware_proto.pdf"> Hardware: Proto board (pdf)</a></li>
 <li><a href="docs/Raspberry_Pi_dryer_hardware_proto_schematics.pdf"> Hardware: Proto board schematics (pdf)</a></li>
 <li><a href="docs/Raspberry_Pi_dryer_hardware_relay.pdf"> Hardware: Relay board (pdf)</a></li>
 <li><a href="docs/Raspberry_Pi_dryer_hardware_assembling.pdf"> Hardware: Assembling (sofar only pictures) (pdf)</a></li>
 <li><a href="docs/Raspberry_Pi_dryer_blynk.pdf"> Software: Blynk remote control interface (pdf)</a></li>
 </ul>

Modules required
 <ul>
  <li><a href="https://www.npmjs.com/package/node-fs">node-fs</a><br/>
    $ npm install node-fs</li>
  <li><a href="https://www.npmjs.com/package/blynk-library">blynk-library</a><br/>
    $ npm install blynk-library</li>
  <li><a href="https://github.com/momenso/node-dht-sensor">node-dht-sensor</a><br/>
    $ npm install node-dht-sensor</li>
  <li><a href="https://github.com/fivdi/onoff">onoff</a><br/>
    $ npm install onoff</li>
 </ul>

