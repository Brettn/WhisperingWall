/* Arduino WaveRP Library
 * Copyright (C) 2009 by William Greiman
 *  
 * This file is part of the Arduino WaveRP Library
 *  
 * This Library is free software: you can redistribute it and/or modify 
 * it under the terms of the GNU General Public License as published by 
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 * 
 * This Library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *  
 * You should have received a copy of the GNU General Public License
 * along with the Arduino WaveRP Library.  If not, see
 * <http://www.gnu.org/licenses/>.
 */
#include <WaveRP.h>
#include "freeRam.h"
#include <SdFat.h>
#include <Sd2Card.h>
#include "PgmPrint.h"
#include <ctype.h>
#include <EEPROM.h>

/**
 * Example Arduino record/play sketch for the Adafruit Wave Shield.
 * For best results use Wave Shield version 1.1 or later.
 *
 * The SD/SDHC card should be formatted with 32KB allocation units/clusters.
 * Cards with 2GB or less should be formatted FAT16 to minimize file
 * system overhead. If possible use SDFormatter from 
 * www.sdcard.org/consumers/formatter/
 *  
 * The user must supply a microphone preamp that delivers a 0 - 5 volt audio
 * signal to analog pin zero.  The preamp should deliver 2.5 volts for silence.
 *
 */
// record rate - must be in the range 4000 to 44100 samples per second
// best to use standard values like 8000, 11025, 16000, 22050, 44100
#define RECORD_RATE 11025
//#define RECORD_RATE 44100
//
// max recorded file size.  Size should be a multiple of cluster size. 
// the recorder creates and erases a contiguous file of this size.
// 100*1024*1024 bytes - about 100 MB or 150 minutes at 11025 samples/second
#define MAX_FILE_SIZE 104857600UL  // 100 MB
//#define MAX_FILE_SIZE 1048576000UL // 1 GB
//
// print the ADC range while recording
#define DISPLAY_RECORD_LEVEL 1
//
// print a '.' every 500 ms while playing a file
#define PRINT_PLAYER_PERIOD 0
//
// print file info - useful for debug
#define PRINT_FILE_INFO 0
//
// print bad wave file size and SD busy errors for debug
#define PRINT_DEBUG_INFO 0
//------------------------------------------------------------------------------
// global variables
Sd2Card card;           // SD/SDHC card with support for version 2.00 features
SdVolume vol;           // FAT16 or FAT32 volume
SdFile root;            // volume's root directory
SdFile file;            // current file
WaveRP wave;            // wave file recorder/player
int16_t lastTrack = -1; // Highest track number
uint8_t trackList[32];  // bit list of used tracks


int prevTrack_addr = 0;
int totalTrack_addr = 1;
int prevTrack;
int totalTrack;
int record_LED = 6;  //pin # for green "Record" LED
int standby_LED = 9;  //pin # for "Standby" LED
int record_button = 8;  //pin # for "Record" button
int delete_all_files = 7;  //pin # for jumper to erase all files
//------------------------------------------------------------------------------
// print error message and halt
void error(char *str)
{
  PgmPrint("error: ");
  Serial.println(str);
  if (card.errorCode()) {
    PgmPrint("sdError: ");Serial.println(card.errorCode(), HEX);
    PgmPrint("sdData: ");Serial.println(card.errorData(), HEX); 
  }
  while(1);
}
//------------------------------------------------------------------------------
// print help message
void help(void)
{
  PgmPrintln("a     play all WAV files in the root dir");
  PgmPrintln("c     clear - deletes all tracks");
  PgmPrintln("<n>d  delete track number <n>");
  PgmPrintln("h     help");
  PgmPrintln("l     list track numbers");
  PgmPrintln("p     play last track");
  PgmPrintln("<n>p  play track number <n>");
  PgmPrintln("r     record new track as last track");
  PgmPrintln("<n>r  record over deleted track <n>");
}
//------------------------------------------------------------------------------
// clear all bits in track list
void listClear(void) 
{
  memset(trackList, 0, sizeof(trackList));
}
//------------------------------------------------------------------------------
// return bit for track n
uint8_t listGet(uint8_t n)
{
  return (trackList[n >> 3] >> (n & 7)) & 1;
}
//------------------------------------------------------------------------------
// print list of tracks in ten columns with each column four characters wide
void listPrint(void)
{
  PgmPrintln("\nTrack list:");
  uint8_t n = 0;
  uint8_t nc = 0;
  do {
    if (!listGet(n)) continue;
    if (n < 100) Serial.print(' ');
    if (n < 10) Serial.print(' ');
    Serial.print(n, DEC);
    if (++nc == 10) {
      Serial.println();
      nc = 0;
    }
    else {
      Serial.print(' ');
    }
  } while (n++ != 255);
  if (nc) Serial.println();
}
//------------------------------------------------------------------------------
// set bit for track n
void listSet(uint8_t n)
{
  trackList[n >> 3] |= 1 << (n & 7);
}
//------------------------------------------------------------------------------
// Nag user about power and SD card
void nag(void) 
{
  PgmPrintln("\nTo avoid USB noise use a DC adapter or battery for Arduino power."); 
  uint8_t bpc = vol.blocksPerCluster();
  PgmPrint("BlocksPerCluster: ");
  Serial.println(bpc, DEC);
  uint8_t align = vol.dataStartBlock() & 0X3F;
  PgmPrint("Data alignment: ");
  Serial.println(align, DEC);
  PgmPrint("sdCard size: ");
  Serial.print(card.cardSize()/2000UL);PgmPrintln(" MB");
  if (align || bpc < 64) {
    PgmPrintln("\nFor best results use a 2 GB or larger card.");
    PgmPrintln("Format the card with 64 blocksPerCluster and alignment = 0.");
    PgmPrintln("If possible use SDFormater from www.sdcard.org/consumers/formatter/");
  }
  if (!card.eraseSingleBlockEnable()) {
    PgmPrintln("\nCard is not erase capable and can't be used for recording!");
  }
}
//------------------------------------------------------------------------------
// check for pause resume
void pauseResume(void)
{
  if ((digitalRead(record_button) == LOW) && (wave.isRecording())) wave.stop();
  else if ((digitalRead(record_button) == HIGH) && (wave.isPlaying())) wave.stop();


//  else
//  {
//  
//  if (!Serial.available()) return;
//  uint8_t c = Serial.read();
//  if (c != 's') {
//    PgmPrintln("\nPaused - type 's' to stop other to resume");
//    wave.pause();
//    Serial.flush();
//    while (!Serial.available());
//    c = Serial.read();
//  }
//  if (c == 's') {
//    wave.stop();
//  }
//  else {
//    wave.resume();

}
//------------------------------------------------------------------------------
// play all files in the root dir
void playAll(void)
{
  dir_t dir;
  char name[13];
  uint8_t np = 0;
  root.rewind();
  while (root.readDir(dir) == sizeof(dir)) {
    //only play wave files
    if (strncmp_P((char *)&dir.name[8], PSTR("WAV"), 3)) continue;
    // remember current dir position
    uint32_t pos = root.curPosition();
    // format file name
    SdFile::dirName(dir, name);
    playFile(name);
    // restore dir position
    root.seekSet(pos);
  }
}
//------------------------------------------------------------------------------
// play a file
void playFile(char * name)
{
  if (!file.open(root, name)) {
    PgmPrint("Can't open: ");
    Serial.println(name);
    return;
  }
  if (!wave.play(file)) {
    PgmPrint("Can't play: ");Serial.println(name);
    file.close();
    return;
  }
  PgmPrint("Playing: ");Serial.print(name);
#if PRINT_FILE_INFO
  PgmPrint(", ");
  Serial.print(wave.bitsPerSample, DEC);
  PgmPrint("-bit, ");
  Serial.print(wave.sampleRate/1000);
  PgmPrint(" kps");
#endif // PRINT_FILE_INFO
  PgmPrintln(", type 's' to skip file other to pause");
#if PRINT_DEBUG_INFO    
  if (wave.sdEndPosition != file.fileSize()) {
    PgmPrint("play Size mismatch,");Serial.print(file.fileSize());
    Serial.print(',');Serial.println(wave.sdEndPosition);
  }
#endif // PRINT_DEBUG_INFO     
  while (wave.isPlaying()) {
#if PRINT_PLAYER_PERIOD  
    delay(500);
    Serial.print('.');
#endif //PRINT_PLAYER_PERIOD
    pauseResume();
    delay(500);
    Serial.print(".");
  }
#if PRINT_PLAYER_PERIOD 
  Serial.println();
#endif //PRINT_PLAYER_PERIOD
  file.close();
#if PRINT_DEBUG_INFO
  if (wave.errors()) {
    PgmPrint("busyErrors: ");
    Serial.println(wave.errors(), DEC);
  }
#endif // PRINT_DEBUG_INFO 
}
//------------------------------------------------------------------------------
void recordFile(char *name)
{
  PgmPrint("Creating: "); Serial.println(name);
  if (!file.createContiguous(root, name, MAX_FILE_SIZE)) {
    PgmPrint("Can't create: ");
    Serial.println(name);
    return;
  }
  if(!wave.record(file, RECORD_RATE)) {
    PgmPrint("Record failed for: ");
    Serial.println(name);
    file.close();
    return;
  }
  digitalWrite(record_LED, HIGH);  //turn on "Ready to record" LED
  digitalWrite(standby_LED, LOW);  //turn off "Standby" LED
  PgmPrintln("Recording - type 's' to stop other to pause");
  while (wave.isRecording()) {
#if DISPLAY_RECORD_LEVEL    
    wave.adcClearRange();
    delay(500);
    uint8_t h = wave.adcGetRange();
    Serial.print(h, DEC);Serial.print(' ');
#endif // DISPLAY_RECORD_LEVEL    
    pauseResume();
  }
  // trim unused space from file
  wave.trim(file);
  file.close();
#if PRINT_DEBUG_INFO
  if (wave.errors() ){
    PgmPrint("busyErrors: ");
    Serial.println(wave.errors(), DEC);
  }
#endif // PRINT_DEBUG_INFO   
}
//------------------------------------------------------------------------------
// scan root directory for track list and recover partial tracks
void scanRoot(void)
{
  dir_t dir;
  char name[13];
  listClear();
  root.rewind();
  lastTrack = -1;
  while (root.readDir(dir) == sizeof(dir)) {
    // only accept TRACKnnn.WAV with nnn < 256
    if (strncmp_P((char *)dir.name, PSTR("TRACK"), 5)) continue;
    if (strncmp_P((char *)&dir.name[8], PSTR("WAV"), 3)) continue;
    int16_t n = 0;
    uint8_t i;
    for (i = 5; i < 8 ; i++) {
      char c = (char)dir.name[i];
      if (!isdigit(c)) break;
      n *= 10;
      n += c - '0';
    }
    // nnn must be three digits and less than 256 
    if (i != 8 || n > 255) continue;
    if (n > lastTrack) lastTrack = n;
    // mark track found
    listSet(n);
    if (dir.fileSize != MAX_FILE_SIZE) continue;
    // try to recover untrimmed file
    uint32_t pos = root.curPosition();
    if (!trackName(n, name) || !file.open(root, name) || !wave.trim(file)) {
      if (!file.truncate(0)) {
        PgmPrint("Can't trim: ");
        Serial.println(name);
      }
    }
    file.close();
    root.seekSet(pos);
  }
}
//------------------------------------------------------------------------------
// delete all tracks on SD
void trackClear(void)
{
  char name[13];
//  PgmPrintln("Type Y to delete all tracks!");
//  Serial.flush();
//  while (!Serial.available());
//  if (Serial.read() != 'Y') {
//    PgmPrintln("Delete all canceled!");
//    return;
//  }
  for (uint16_t i = 0; i < 256; i++) {
    if (!listGet(i)) continue;
    if (!trackName(i, name)) return;
    if (!SdFile::remove(root, name)) {
      PgmPrint("Delete failed for: ");
      Serial.println(name);
      return;
    }
  }
  PgmPrintln("Deleted all tracks!");
}
//------------------------------------------------------------------------------
// delete a track
void trackDelete(uint8_t n)
{
  char name[13];
  if (!trackName(n, name)) return;
//  PgmPrint("Type y to delete: "); 
//  Serial.println(name);
//  Serial.flush();
//  while (!Serial.available());
//  if (Serial.read() != 'y') {
//    PgmPrintln("Delete canceled!");
//    return;
//  }
  if (SdFile::remove(root, name)) {
    PgmPrintln("Deleted!");
  }
  else {
    PgmPrintln("Delete failed!");
  }
}
//------------------------------------------------------------------------------
// format a track name in 8.3 format
uint8_t trackName(uint16_t number, char *name)
{
  if (number > 255) {
    PgmPrint("Track number too large: ");
    Serial.println(number);
    return false;
  }
  strcpy_P(name, PSTR("TRACK000.WAV"));
  name[5] = '0' + number/100;
  name[6] = '0' + (number/10)%10;
  name[7] = '0' + number%10;
  return true;
}
//------------------------------------------------------------------------------
// play a track
void trackPlay(uint16_t track)
{
  char name[13];
  if (!trackName(track, name)) return;
  playFile(name);
}
//------------------------------------------------------------------------------
// record a track
void trackRecord(uint16_t track)
{
  char name[13];
  if (!trackName(track , name)) return;
  recordFile(name);
}
//==============================================================================
// Standard Arduino setup() and loop() functions
//------------------------------------------------------------------------------
// setup Serial port and SD card
void setup(void)
{
  Serial.begin(9600); 
  delay(10);
  Serial.print("\nFreeRam: ");
  Serial.println(freeRam());
  if (!card.init()) error("card.init");
  if (!vol.init(card)) error("vol.init");
  if (!root.openRoot(vol)) error("openRoot");
  nag(); // nag user about power and SD card
  
  pinMode(6, OUTPUT);  //"start recording" LED
  pinMode(7, INPUT);  //reset eeprom counters
  pinMode(record_button, INPUT);  //record button...high == pushed
  pinMode(9, OUTPUT);  //"busy" LED
  
  digitalWrite(standby_LED, LOW);
  digitalWrite(record_LED, LOW);
  trackClear();
  if (digitalRead(delete_all_files) == HIGH)  //reset track counters(old files will not play)
  {
    EEPROM.write(prevTrack_addr, 0);
    EEPROM.write(totalTrack_addr, 0);
    
    
  }
  prevTrack = EEPROM.read(prevTrack_addr);
  totalTrack = EEPROM.read(totalTrack_addr);
  Serial.print("\ntotalTrack: ");
  Serial.println(totalTrack);

}
//------------------------------------------------------------------------------
// loop to play and record files.
void loop()
{
   
    if (digitalRead(record_button) == HIGH)
    {   
      digitalWrite(standby_LED, HIGH);
      trackDelete(prevTrack);
      trackRecord(prevTrack);
      digitalWrite(record_LED, LOW);  //turn off "Ready to Record" LED
      digitalWrite(standby_LED, HIGH);  //turn on "Standby" LED
      delay(500);
      trackPlay(prevTrack);
      prevTrack = prevTrack + 1;
      if (prevTrack > 255) prevTrack = 0;
      EEPROM.write(prevTrack_addr, prevTrack);
      if (totalTrack < 255)
      {
        totalTrack = totalTrack + 1;
        EEPROM.write(totalTrack_addr, totalTrack);
      }
      digitalWrite(standby_LED, LOW);  //turn off "Standby" LED
    }
   // uint16_t random_track = random(prevTrack + 1);
   for (int i = 0; i < 12; i++)  // delay 3 seconds between playing each track
   {
     delay(250);  //pause 1/4 second
     if (digitalRead(record_button) == HIGH) i = 12;  //jump out of loop early if button is pressed
   }
   if ((totalTrack > 0) && (digitalRead(record_button) == LOW)) 
   {
     trackPlay(random(totalTrack));
     Serial.print("\ntotalTrack: ");
     Serial.println(totalTrack);
   }
  
  
  
//  // insure file is closed
//  if (file.isOpen()) file.close();
//  // scan root dir to build track list and set lastTrack
//  scanRoot();
//  PgmPrintln("\ntype a command or h for help");
//  int16_t track = -1;
//  uint8_t c;
//  Serial.flush();
//  while(track < 256){
//    while (!Serial.available());
//    c = Serial.read();
//    if (!isdigit(c)) break;
//    track = (track < 0 ? 0 : 10*track) + c - '0';
//  }
//  if (track > lastTrack) {
//    PgmPrintln("track number > last track");
//    return;
//  }
//  Serial.println();
//  if (c == 'a') playAll();
//  else if (c == 'c') trackClear();
//  else if (c == 'd' && track >= 0) trackDelete(track);
//  else if (c == 'h') help();
//  else if (c == 'l') listPrint();
//  else if (c == 'p') trackPlay(track >= 0 ? track : lastTrack > 0 ? lastTrack : 0);
//  else if (c == 'r') trackRecord(track >= 0 ? track : lastTrack + 1);  
//  else PgmPrintln("? - type h for help");
}
