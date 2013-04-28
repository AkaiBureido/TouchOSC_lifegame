require 'ruby-osc'
require 'pry'

# This addition to the array stacks up an array
# as in [1,2,3,4].stack 2 -> [[1,2],[3,4]]
# pretty usefull I think

# As long as you are dealing with 1d arrays it is ok to use default element
# but with anything greater it is not worth the hassle. Nils ftw!

class Array
    def stack number, default = nil
        resultant_array = []

        if number > 0
            shifts = (self.size().to_f / number.to_f()).ceil

            shifts.times { resultant_array.push shift(number) }

            if (last_element_size = resultant_array[-1].size) < number
                resultant_array[-1].concat Array.new(number - last_element_size) { default }
            end
        elsif number < 0
            raise ArgumentError.new.exception "negative array size"
        else
            resultant_array = [[]]
        end

        return resultant_array
    end
end



module IPAD_OSC_SCREEN
    @@messages_sent_lock = Mutex.new
    @@messages_sent = 0

    def self.messages_sent
        @@messages_sent
    end

    def self.reset_messages_sent
        @@messages_sent = 0
    end

    def self.clearScreen device
        clearScreen = Array.new(16*3) { Array.new(16*4) { 0 } }

        clearScreen = splitIntoSubscreens clearScreen, 16, 16

        updateFullScreen device, 3, 4, clearScreen, nil
    end

    # This function updates the full screen on the iPad Touch OSC
    def self.updateFullScreen device, total_rows, total_columns, sub_screen_array, screen_history
        total_rows.times do |row|
            total_columns.times do |column|

                #TODO OPTIMIZE!
                if screen_history
                    if screen_history[row][column] != sub_screen_array[row][column]
                        updateScreeenPortionFor(
                            device, row, column,
                            sub_screen_array[row][column], screen_history[row][column]
                        )
                    end
                else
                    updateScreeenPortionFor(device, row, column, sub_screen_array[row][column], nil)
                end
                ###############

            end
        end
    end

    # This function updates a cell on iPad touch osc. The biggest cell can get is 16
    # My naming convention for multietoggles in Touch OSC is "screen_(ROW_NUM)_(COL_NUM)"
    # Screen history is used to optimise requests. That is -- not updating the things that did not change.
    def self.updateScreeenPortionFor device, screen_row, screen_column, screen_array, screen_history

        # creating buffer for messages so that i am updating the whole cell at a time
        # helps not to miss anything since we are dealing with UDP
        messages = Array.new

        # iterating over square 16x16 array
        16.times do |row|
            16.times do |column|

                #TODO OPTIMIZE!
                if screen_history
                    if screen_history[row][column].to_i != screen_array[row][column].to_i
                        value = screen_array[row][column]
                        messages.push(
                            OSC::Message.new(
                                "/1/screen_#{screen_row}_#{screen_column}/#{row+1}/#{column+1}",
                                value.to_i
                            )
                        )
                    end
                else
                    value = screen_array[row][column]
                    messages.push(
                        OSC::Message.new(
                            "/1/screen_#{screen_row}_#{screen_column}/#{row+1}/#{column+1}",
                            value.to_i
                        )
                    )
                end
                ###############

            end
        end

        device.send OSC::Bundle.new(Time.now, *messages)

        @@messages_sent_lock.synchronize {
           @@messages_sent += 1
        }

    end

    # This functin takes an arbitrary 2D array and splits it into chunks
    # row_view_span, column_viewspan - refer to the subscreen dimentions

    def self.splitIntoSubscreens full_screen_array, row_view_span, column_viewspan

        # finding how many many arrays wold siffice to cover all of our given data
        row_chunks = (full_screen_array.size/row_view_span).ceil
        column_chunks = (full_screen_array[0].size/column_viewspan).ceil

        # crating the array with computed dimentions
        screens = Array.new(row_chunks) { Array.new(column_chunks) }

        screens.each_index do |row|
            screens[row].each_index do |column|
                screens[row][column] =
                    offsetViewInto2DArray(
                        full_screen_array,
                        row*row_view_span,
                        column*column_viewspan,
                        row_view_span,
                        column_viewspan
                    )
            end
        end

        return screens
    end

    # Sort of a neat function that can be used to peek into 2D array at any point even out of bounds
    # However the default value is zero NOT nil
    #
    # It certainly can be neater...

    def self.offsetViewInto2DArray source_array, offset_row, offset_column, row_view_span, column_viewspan
        sub_screen = Array.new(row_view_span) do |row|
            Array.new(column_viewspan) do |column|
                if row_value = source_array[row + offset_row]

                    #I wish I knew a better way to do this...
                    if column_value = row_value[column + offset_column]
                        column_value.to_i
                    else
                        0
                    end
                else
                    0
                end
            end
        end
    end

end


######################################################
#
# This is the code that generates the live game...
# i have taken it form: http://bjorkoy.com/2010/05/conways-game-of-life-in-ruby/
#

class Cell
    attr_writer :neighbors

    def initialize(seed_probability)
        @alive = seed_probability > rand
    end

    def next!
        @alive = @alive ? (2..3) === @neighbors : 3 == @neighbors
    end

    def to_i
        @alive ? 1 : 0
    end

    def to_s
        @alive ? '1' : '0'
    end
end

class Game
    def initialize(port, ip, width, height, seed_probability, steps)
        @width, @height, @steps = width, height, steps
        @port, @ip = port, ip
        @cells = Array.new(height) {
            Array.new(width) { Cell.new(seed_probability) } }
    end

    def play!
        OSC.run do

            # server = OSC::Server.new 9090, "192.168.0.197"

            # server.add_pattern %r{/.*/} do |*args|       # this will match any address
            #     args[0].scan(%r{(?<=_)\d+})
            #     puts "/.*/:       #{ args.join(', ') }"
            # end

            iPad = OSC::Client.new @port, @ip
            IPAD_OSC_SCREEN::clearScreen iPad


            currThread = nil
            screen_history = nil
            time = nil

            (1..@steps).each do |index|
                next!

                # AND THIS WOULD BE MY SMALL ADDITION
                # so that instead of printing to console it prints to iPad.

                windows = IPAD_OSC_SCREEN::splitIntoSubscreens @cells, 16, 16

                if currThread then currThread.join end
                screen_history_copy = Marshal.load( Marshal.dump(screen_history) )
                currThread = Thread.new {
                    iPad = OSC::Client.new @port, @ip
                    IPAD_OSC_SCREEN::updateFullScreen(iPad, 3, 4, windows, screen_history_copy)
                }

                screen_history = Marshal.load( Marshal.dump(windows) )
                sleep 0.1

                if time.nil?
                    time = Time.now
                else
                    if Time.now > time+3
                        time = Time.now
                        puts "Messages Sent: #{IPAD_OSC_SCREEN::messages_sent} Current Step: #{index}"
                    end
                end
            end
            ##########################################################
        end
    end

    def next!
        @cells.each_with_index do |row, y|
            row.each_with_index do |cell, x|
                cell.neighbors = alive_neighbours(y, x)
            end
        end

        @cells.each { |row| row.each { |cell| cell.next! } }
    end

    def alive_neighbours(y, x)
        [
            [-1, 0], [1, 0], # sides
            [-1, 1], [0, 1], [1, 1], # over
            [-1, -1], [0, -1], [1, -1] # under

        ].inject(0) do |sum, pos|
            sum + @cells[(y + pos[0]) % @height][(x + pos[1]) % @width].to_i
        end
    end

    def to_s
        @cells.map { |row| row.join }.join("\n")
    end
end

begin
    Game.new(9000, "192.168.0.192", 16*4, 16*3, 0.6, 1000).play!
rescue SystemExit, Interrupt
    puts "\n\nBye!\n"
    exit
end














